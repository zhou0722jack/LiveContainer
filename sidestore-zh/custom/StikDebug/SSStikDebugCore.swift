// SideStore integration using StikDebug's recommended StikJIT framework.
// Remote app enumeration follows StikDebug/IdeviceFFIBridge.swift (AGPL-3.0).
// StikJIT and its bundled scripts retain their upstream MPL-2.0 license.
import Foundation
import Darwin
@_implementationOnly import idevice

@objc(SSStikDebugCore)
public final class SSStikDebugCore: NSObject {
    private static let instance = SSStikDebugCore()
    private let queue = DispatchQueue(label: "SideStore.StikDebug.serial", qos: .userInitiated)
    @objc public class func shared() -> NSObject { instance }

    @objc public func execute(_ request: NSDictionary) {
        guard let reply = request["reply"] as? NSObject else { return }
        queue.async {
            func progress(_ message: String) {
                DispatchQueue.main.async { _ = reply.perform(NSSelectorFromString("progress:"), with: message) }
            }
            func complete(_ result: [String: Any]) {
                DispatchQueue.main.async { _ = reply.perform(NSSelectorFromString("complete:"), with: result as NSDictionary) }
            }
            do {
                let operation = request["operation"] as? String ?? ""
                let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                let paths = DDIPaths.default(in: library.appendingPathComponent("SideStoreStikDebug"))
                if operation == "reset" {
                    try StikJIT.resetCachedDDI(at: paths)
                    complete(["message": "DDI 缓存已重置，下次准备时重新下载。"])
                    return
                }
                guard let file = request["pairingPath"] as? String,
                      FileManager.default.isReadableFile(atPath: file),
                      let address = request["address"] as? String,
                      let port = request["port"] as? NSNumber,
                      (1...65535).contains(port.intValue) else { throw Self.failure("缺少有效配对文件或连接地址。") }
                var parsed = in_addr()
                guard inet_pton(AF_INET, address, &parsed) == 1 else { throw Self.failure("请输入有效的设备 IPv4 地址。") }
                let config = StikJIT.Configuration(deviceAddress: address, rsdPort: port.uint16Value)
                let pairing = URL(fileURLWithPath: file)
                if let reason = EndpointProbe.failureReason(address: address, port: port.uint16Value, timeout: 5) {
                    throw Self.failure(reason)
                }
                let reportStage: (StikJIT.PreparationStage) -> Void = { stage in
                    switch stage {
                    case .checkingReachability: progress("检查设备连接…")
                    case .checkingDDI: progress("检查开发者磁盘镜像…")
                    case .downloadingDDI(let fraction, let status): progress("下载 DDI \(Int(fraction * 100))%：\(status)")
                    case .mountingDDI(let fraction): progress("挂载 DDI \(Int(fraction * 100))%…")
                    case .verifyingDDI: progress("确认 DDI 挂载…")
                    case .ready: progress("设备已准备。")
                    }
                }
                func prepare() throws -> StikJIT.DeviceSecurityState {
                    switch StikJIT.prepareDevice(pairingFile: pairing, paths: paths, configuration: config, progress: reportStage) {
                    case .ready(let state): return state
                    case .unreachable(let reason), .preparationFailed(let reason): throw Self.failure(reason)
                    }
                }
                if operation == "prepare" {
                    let state = try prepare()
                    complete(["message": "设备准备完成；TXM/SPTM：" + (state.isTXMPresent.map { $0 ? "存在" : "不存在" } ?? "未知")])
                    return
                }
                guard operation == "list" || operation == "enable" else { throw Self.failure("不支持的调试操作。") }
                let remote = try RemoteDevice(pairing: file, config: config)
                let excluded = Set(request["excludedBundleIDs"] as? [String] ?? [])
                let apps = try remote.debuggableApps().filter { !excluded.contains($0["bundleID"] ?? "") }
                if operation == "list" { complete(["apps": apps, "message": "已找到 \(apps.count) 个可调试 App。"]); return }
                guard operation == "enable", let bundleID = request["bundleID"] as? String,
                      apps.contains(where: { $0["bundleID"] == bundleID }) else {
                    throw Self.failure("目标 App 不在可调试列表中，或缺少 get-task-allow；不能调试当前二合一宿主。")
                }
                _ = try prepare()
                progress("启动目标 App…")
                let pid = try remote.launch(bundleID)
                guard pid > 0, pid != getpid() else { throw Self.failure("不能从当前进程为自身启用 JIT。") }
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairing, ddiPaths: paths,
                    configuration: config, script: .universal,
                    forceScript: request["forceScript"] as? Bool ?? false,
                    preparationProgress: reportStage, progress: progress)
                complete(["message": "JIT 调试流程已完成。目标 App 是否能够执行 JIT，仍需在目标内验证。"])
            } catch { complete(["error": error.localizedDescription]) }
        }
    }

    fileprivate static func failure(_ reason: String) -> NSError {
        NSError(domain: "SideStore.StikDebug", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

// Each request owns its handles; FFI work stays on the core's serial queue.
private final class RemoteDevice {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?

    init(pairing: String, config: StikJIT.Configuration) throws {
        var pair: OpaquePointer?
        try IdeviceFFI.check("读取配对文件失败") { rp_pairing_file_read(pairing, &pair) }
        guard let pair else { throw SSStikDebugCore.failure("配对文件无效。") }
        defer { rp_pairing_file_free(pair) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_port = config.rsdPort.bigEndian
        guard inet_pton(AF_INET, config.deviceAddress, &address.sin_addr) == 1 else { throw SSStikDebugCore.failure("设备地址无效。") }
        do {
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socket in
                    try IdeviceFFI.check("创建调试隧道失败") {
                        tunnel_create_rppairing(socket, socklen_t(MemoryLayout<sockaddr_in>.stride), "SideStoreStikDebug", pair, nil, nil, &adapter, &handshake)
                    }
                }
            }
            guard adapter != nil, handshake != nil else { throw SSStikDebugCore.failure("调试隧道句柄不完整。") }
        } catch { release(); throw error }
    }

    private func release() {
        if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
        if let adapter { adapter_free(adapter); self.adapter = nil }
    }
    deinit { release() }

    func debuggableApps() throws -> [[String: String]] {
        var client: OpaquePointer?
        try IdeviceFFI.check("连接 App 列表服务失败") { installation_proxy_connect_rsd(adapter, handshake, &client) }
        defer { if let client { installation_proxy_client_free(client) } }
        var raw: UnsafeMutableRawPointer?
        var count = 0
        try IdeviceFFI.check("读取 App 列表失败") { installation_proxy_get_apps(client, nil, nil, 0, &raw, &count) }
        guard let raw else { return [] }
        let apps = raw.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count { plist_free(apps[index]) }
            idevice_data_free(raw.assumingMemoryBound(to: UInt8.self), UInt(count * MemoryLayout<plist_t?>.stride))
        }
        var result: [[String: String]] = []
        for index in 0..<count {
            var binary: UnsafeMutablePointer<CChar>?
            var length: UInt32 = 0
            guard plist_to_bin(apps[index], &binary, &length) == PLIST_ERR_SUCCESS, let binary else { continue }
            let data = Data(bytes: binary, count: Int(length))
            plist_mem_free(binary)
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let entitlements = info["Entitlements"] as? [String: Any],
                  (entitlements["get-task-allow"] as? NSNumber)?.boolValue == true,
                  let identifier = info["CFBundleIdentifier"] as? String else { continue }
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? identifier
            result.append(["name": name, "bundleID": identifier])
        }
        return result.sorted { ($0["name"] ?? "").localizedStandardCompare($1["name"] ?? "") == .orderedAscending }
    }

    func launch(_ bundleID: String) throws -> Int32 {
        var server: OpaquePointer?
        try IdeviceFFI.check("连接进程服务失败") { remote_server_connect_rsd(adapter, handshake, &server) }
        defer { if let server { remote_server_free(server) } }
        var control: OpaquePointer?
        try IdeviceFFI.check("创建进程控制失败") { process_control_new(server, &control) }
        defer { if let control { process_control_free(control) } }
        var pid: UInt64 = 0
        try IdeviceFFI.check("启动 App 失败") { process_control_launch_app(control, bundleID, nil, 0, nil, 0, false, false, &pid) }
        guard pid > 0, pid <= UInt64(Int32.max) else { throw SSStikDebugCore.failure("目标 PID 无效。") }
        return Int32(pid)
    }
}
