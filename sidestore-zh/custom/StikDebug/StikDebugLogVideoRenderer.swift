import UIKit
import CoreVideo
import CoreMedia

@MainActor
final class StikDebugLogVideoRenderer {
    static let size = CGSize(width: 960, height: 640)
    private var cachedKey: String?
    private var cachedBuffer: CVPixelBuffer?

    func pixelBuffer(for session: StikDebugLogSession) throws -> CVPixelBuffer {
        let key = "\(session.id)-\(session.revision)-\(session.finished)"
        if key == cachedKey, let cachedBuffer { return cachedBuffer }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { graphics in
            UIColor(red: 0.035, green: 0.05, blue: 0.08, alpha: 1).setFill()
            graphics.fill(CGRect(origin: .zero, size: Self.size))
            let titleStyle: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor.white]
            ("JIT · " + session.name as NSString).draw(in: CGRect(x: 24, y: 18, width: 912, height: 46), withAttributes: titleStyle)
            let color: UIColor = session.failed ? .systemRed : (session.finished ? .systemGreen : .systemCyan)
            (session.status as NSString).draw(in: CGRect(x: 24, y: 72, width: 912, height: 66), withAttributes: [
                .font: UIFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: color])
            let body = CGRect(x: 24, y: 150, width: 912, height: 466)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            paragraph.lineSpacing = 5
            let style: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                .foregroundColor: UIColor(white: 0.9, alpha: 1), .paragraphStyle: paragraph]
            var visible: [String] = []
            for entry in session.entries.reversed() {
                let compact = entry.replacingOccurrences(of: #"\[\d{4}-\d{2}-\d{2}T"#, with: "[", options: .regularExpression)
                    .replacingOccurrences(of: "Z]", with: "]")
                let candidate = ([String(compact.suffix(700))] + visible).joined(separator: "\n")
                let height = (candidate as NSString).boundingRect(with: CGSize(width: body.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: style, context: nil).height
                if height > body.height, !visible.isEmpty { break }
                visible.insert(String(compact.suffix(700)), at: 0)
            }
            graphics.cgContext.saveGState()
            graphics.cgContext.clip(to: body)
            (visible.joined(separator: "\n") as NSString).draw(in: body, withAttributes: style)
            graphics.cgContext.restoreGState()
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let result = CVPixelBufferCreate(kCFAllocatorDefault, Int(Self.size.width), Int(Self.size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard result == kCVReturnSuccess, let buffer = pixelBuffer else { throw failure("创建日志视频帧失败：\(result)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(Self.size.width), height: Int(Self.size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw failure("无法创建日志视频绘图上下文。")
        }
        context.translateBy(x: 0, y: Self.size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: Self.size))
        UIGraphicsPopContext()
        cachedKey = key
        cachedBuffer = buffer
        return buffer
    }

    func sampleBuffer(for session: StikDebugLogSession, at time: CMTime) throws -> CMSampleBuffer {
        let buffer = try pixelBuffer(for: session)
        var description: CMVideoFormatDescription?
        var result = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &description)
        guard result == noErr, let description else { throw failure("创建日志视频格式失败：\(result)") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        result = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw failure("创建日志视频样本失败：\(result)") }
        return sample
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "SideStore.JITLogVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
