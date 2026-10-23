import Foundation
import Darwin

// This coordinator stays in LiveContainer. All blocking device/debug work runs
// in a separate instance of its existing LiveProcess extension.
@MainActor
final class LCBuiltInJIT: NSObject {
    private static let shared = LCBuiltInJIT()
    private var continuation: CheckedContinuation<Void, Error>?
    private var logger: ((String) -> Void)?
    private var handle: UnsafeMutableRawPointer?
    private var containerLaunchInProgress = false

    static func beginContainerLaunch() throws {
        guard !shared.containerLaunchInProgress else { throw error("已有容器正在准备内置 JIT，请等待完成。") }
        shared.containerLaunchInProgress = true
    }
    static func endContainerLaunch() { shared.containerLaunchInProgress = false }

    static func stageFullScreenLaunch(app: String, container: String, script: String?) throws {
        guard !app.isEmpty, !container.isEmpty else { throw error("全屏启动目标为空。") }
        var handoff: [String: Any] = ["app": app, "container": container,
            "created": Date(), "originPID": Int(getpid())]
        if let script, !script.isEmpty {
            guard let data = Data(base64Encoded: script), data.count <= 1024 * 1024,
                  String(data: data, encoding: .utf8) != nil else { throw error("容器 JIT 脚本格式无效。") }
            handoff["scriptData"] = script
        }
        UserDefaults.standard.set(handoff, forKey: "SSBuiltInJITFullScreenLaunch")
    }

    static func prepare(progress: ((String) -> Void)? = nil) async throws {
        try await shared.perform(operation: "prepare", pid: nil, script: nil, progress: progress)
    }

    static func enable(pid: Int, script: String?, progress: ((String) -> Void)? = nil) async throws {
        guard pid > 0, pid <= Int(Int32.max) else { throw error("容器 PID 无效。") }
        try await shared.perform(operation: "enablePID", pid: pid, script: script, progress: progress)
    }

    private func perform(operation: String, pid: Int?, script: String?, progress: ((String) -> Void)?) async throws {
        guard #available(iOS 17.4, *) else { throw Self.error("内置 JIT 需要 iOS 17.4 或更新版本。") }
        guard continuation == nil else { throw Self.error("已有内置 JIT 操作正在进行。") }
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil),
              (value.takeRetainedValue() as? NSNumber)?.boolValue == true else {
            throw Self.error("此安装缺少 get-task-allow。请使用保留调试权限的方式签名安装。")
        }
        let home = getenv("LC_HOME_PATH").map { String(cString: $0) } ?? NSHomeDirectory()
        let sideStore = URL(fileURLWithPath: home).appendingPathComponent("Documents/SideStore")
        let pairing = sideStore.appendingPathComponent("Documents/PairingFile_RemoteRP.plist")
        guard FileManager.default.isReadableFile(atPath: pairing.path) else {
            throw Self.error("请先在内置 SideStore 的配对管理中导入 Remote Pairing 文件。")
        }
        let configURL = sideStore.appendingPathComponent("Library/Preferences/SSBuiltInJITConnection.plist")
        let config = NSDictionary(contentsOf: configURL) as? [String: Any] ?? [:]
        let address = config["address"] as? String ?? "10.7.0.1"
        let port = config["port"] as? Int ?? 49152
        let path = Bundle.main.bundleURL.appendingPathComponent("Frameworks/SideStoreStikDebugCore.framework/SideStoreStikDebugCore").path
        if handle == nil { handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) }
        guard handle != nil,
              let type = NSClassFromString("SSStikDebugCore") as? NSObject.Type,
              let core = type.perform(NSSelectorFromString("shared"))?.takeUnretainedValue() as? NSObject,
              core.responds(to: NSSelectorFromString("executeWithHelper:")) else {
            throw Self.error("无法加载内置 JIT 核心，请重新安装完整二合一包并保留扩展。")
        }
        var request: [String: Any] = ["operation": operation, "reply": self,
            "hostBundlePath": Bundle.main.bundlePath, "pairingPath": pairing.path,
            "address": address, "port": port]
        if let pid { request["targetPID"] = pid }
        if let script, !script.isEmpty { request["scriptData"] = script }
        logger = progress
        defer { logger = nil }
        try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
            continuation = next
            _ = core.perform(NSSelectorFromString("executeWithHelper:"), with: request as NSDictionary)
        }
    }

    @objc func progress(_ message: String) { logger?(message) }
    @objc func complete(_ result: NSDictionary) {
        guard let next = continuation else { return }
        continuation = nil
        if let error = result["error"] as? String { next.resume(throwing: Self.error(error)) }
        else { next.resume() }
    }
    private static func error(_ message: String) -> NSError {
        NSError(domain: "LiveContainer.BuiltInJIT", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
