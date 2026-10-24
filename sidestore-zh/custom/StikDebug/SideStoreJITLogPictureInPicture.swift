import UIKit
@preconcurrency import AVKit
import AVFoundation
import CoreMedia

@available(iOS 17.4, *)
@MainActor
enum SideStoreJITLogPictureInPicture {
    private static var current: StikDebugPiPController?
    static var isActive: Bool { current?.isActive == true }

    static func show(_ session: StikDebugLogSession, sourceScene: UIWindowScene?, whenReady: @escaping () -> Void = {}) -> String? {
        if let current {
            current.display(session, whenReady: whenReady)
            return nil
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            let message = "此设备不支持系统画中画；请在实验页查看 JIT 结果并复制日志。"
            session.notePresentationIssue(message)
            whenReady()
            return message
        }
        let scene = sourceScene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first(where: { !$0.isHidden }) else {
            let message = "无法定位日志视频的播放场景；请在实验页查看 JIT 结果。"
            session.notePresentationIssue(message)
            whenReady()
            return message
        }
        do {
            let controller = try StikDebugPiPController(session: session, window: window)
            current = controller
            controller.display(session, whenReady: whenReady)
            return nil
        } catch {
            session.notePresentationIssue(error.localizedDescription)
            whenReady()
            return error.localizedDescription
        }
    }

    fileprivate static func release(_ value: StikDebugPiPController) {
        if current === value { current = nil }
    }
}

@available(iOS 17.4, *)
private final class StikDebugVideoSourceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

@available(iOS 17.4, *)
@MainActor
@objc(SSStikDebugPiPController)
private final class StikDebugPiPController: NSObject, AVPictureInPictureControllerDelegate {
    private var session: StikDebugLogSession
    private let sourceView = StikDebugVideoSourceView()
    private let renderer = StikDebugLogVideoRenderer()
    private var controller: AVPictureInPictureController!
    private var timebase: CMTimebase!
    private var playback: StikDebugPiPPlaybackDelegate!
    private var observation: NSKeyValueObservation?
    private var frameTask: Task<Void, Never>?
    private var startTimeout: Task<Void, Never>?
    private var readyCallbacks: [() -> Void] = []
    private var requested = false
    private var closed = false
    var isActive: Bool { controller?.isPictureInPictureActive == true }
    private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    init(session: StikDebugLogSession, window: UIWindow) throws {
        self.session = session
        super.init()
        let audio = AVAudioSession.sharedInstance()
        previousAudio = (audio.category, audio.mode, audio.categoryOptions)
        do {
            // Match SideStore's existing audio-service category; do not add an
            // artificial audio loop or deactivate its background audio later.
            try audio.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try audio.setActive(true)
            var clock: CMTimebase?
            let status = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock)
            guard status == noErr, let clock else { throw failure("无法创建日志视频时钟：\(status)") }
            timebase = clock
            CMTimebaseSetTime(clock, time: .zero)
            CMTimebaseSetRate(clock, rate: 1)
            sourceView.isUserInteractionEnabled = false
            sourceView.frame = CGRect(x: max(0, window.bounds.width - 172),
                y: max(window.safeAreaInsets.top, window.bounds.height - window.safeAreaInsets.bottom - 118), width: 160, height: 106)
            sourceView.layer.cornerRadius = 8
            sourceView.clipsToBounds = true
            window.addSubview(sourceView)
            sourceView.displayLayer.videoGravity = .resizeAspect
            sourceView.displayLayer.controlTimebase = clock
            try enqueueFrame()
            playback = StikDebugPiPPlaybackDelegate(timebase: clock)
            let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: sourceView.displayLayer, playbackDelegate: playback)
            controller = AVPictureInPictureController(contentSource: content)
            controller.delegate = self
            controller.requiresLinearPlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.requestIfPossible() }
            }
        } catch {
            sourceView.removeFromSuperview()
            restoreAudioCategory()
            throw error
        }
    }

    func display(_ value: StikDebugLogSession, whenReady: @escaping () -> Void) {
        session = value
        if controller.isPictureInPictureActive { whenReady(); return }
        readyCallbacks.append(whenReady)
        if frameTask == nil {
            frameTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, !self.closed else { return }
                    do { if !self.playback.isPaused { try self.enqueueFrame() } }
                    catch { self.stopWithIssue(error.localizedDescription); return }
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                }
            }
        }
        requestIfPossible()
        if startTimeout == nil {
            startTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, !self.controller.isPictureInPictureActive, !self.closed else { return }
                let layer = self.sourceView.displayLayer
                let detail = "possible=\(self.controller.isPictureInPicturePossible), layerStatus=\(layer.status.rawValue)"
                self.stopWithIssue("系统未在时限内开启日志画中画（\(detail)）；不会取消已提交的 JIT 请求，请在实验页查看实际结果。")
            }
        }
    }

    private func enqueueFrame() throws {
        let layer = sourceView.displayLayer
        if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        let sample = try renderer.sampleBuffer(for: session, at: CMTimebaseGetTime(timebase))
        layer.enqueue(sample)
    }

    private func requestIfPossible() {
        guard !closed, !requested, controller?.isPictureInPicturePossible == true else { return }
        requested = true
        controller.startPictureInPicture()
    }

    private func releaseReadyCallbacks() {
        let callbacks = readyCallbacks
        readyCallbacks = []
        callbacks.forEach { $0() }
    }

    private func restoreAudioCategory() {
        guard let previousAudio else { return }
        self.previousAudio = nil
        let audio = AVAudioSession.sharedInstance()
        if audio.category == .playback, audio.mode == .default, audio.categoryOptions == .mixWithOthers,
           previousAudio.0 != .playback || previousAudio.1 != .default || previousAudio.2 != .mixWithOthers {
            try? audio.setCategory(previousAudio.0, mode: previousAudio.1, options: previousAudio.2)
        }
    }

    private func stopWithIssue(_ message: String) {
        session.notePresentationIssue(message)
        controller?.stopPictureInPicture()
        cleanup()
    }

    private func cleanup() {
        guard !closed else { return }
        closed = true
        startTimeout?.cancel()
        frameTask?.cancel()
        observation?.invalidate()
        sourceView.removeFromSuperview()
        restoreAudioCategory()
        // PiP is a viewer. Stopping/failing it must not cancel JIT or leave the
        // prepared execution closure waiting forever.
        releaseReadyCallbacks()
        SideStoreJITLogPictureInPicture.release(self)
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { pictureInPictureController.stopPictureInPicture(); return }
            self.startTimeout?.cancel()
            // Keep the inline AV layer attached throughout system PiP.
            self.releaseReadyCallbacks()
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let detail = error as NSError
        let message = "\(detail.localizedDescription) [\(detail.domain):\(detail.code)]"
        Task { @MainActor [weak self] in self?.stopWithIssue(message) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.cleanup() }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor [weak self] in
            self?.sourceView.isHidden = false
            completionHandler(self?.sourceView.window != nil)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "SideStore.JITLogPiP", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// AVKit can ask synchronous playback questions outside the main actor. Keep
// this small delegate lock-protected and dispatch only UI work to the main actor.
@available(iOS 17.4, *)
private final class StikDebugPiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let lock = NSLock()
    private var paused = false
    private let timebase: CMTimebase
    init(timebase: CMTimebase) { self.timebase = timebase; super.init() }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        lock.lock()
        paused = !playing
        CMTimebaseSetRate(timebase, rate: playing ? 1 : 0)
        lock.unlock()
        Task { @MainActor in pictureInPictureController.invalidatePlaybackState() }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { isPaused }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
}
