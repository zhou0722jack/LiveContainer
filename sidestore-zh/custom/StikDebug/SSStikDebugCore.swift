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

    @objc public func executeWithHelper(_ request: NSDictionary) {
        guard let values = request as? [String: Any] else { return }
        SSStikDebugExecuteInHelper(values)
    }
    @objc public func containerApps(_ request: NSDictionary) -> NSDictionary {
        guard let values = request as? [String: Any] else { return ["error": "容器请求格式无效。"] }
        return SSStikDebugContainerApps(values) as NSDictionary
    }
    @objc public func launchContainer(_ request: NSDictionary) -> NSDictionary {
        guard let values = request as? [String: Any] else { return ["error": "容器请求格式无效。"] }
        return SSStikDebugLaunchContainer(values) as NSDictionary
    }

    @objc public func execute(_ request: NSDictionary) {
        guard let reply = request["reply"] as? NSObject else { return }
        queue.async {
            func progress(_ message: String) {
                DispatchQueue.main.async { _ = reply.perform(NSSelectorFromString("progress:"), with: message) }
            }
            func complete(_ result: [String: Any]) {
                DispatchQueue.main.async { _ = reply.perform(NSSelectorFromString("complete:"), with: result as NSDictionary) }
            }
            var stage = "检查参数"
            do {
                let operation = request["operation"] as? String ?? ""
                let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                let paths = DDIPaths.default(in: library.appendingPathComponent("SideStoreStikDebug"))
                if operation == "reset" {
                    stage = "重置 DDI 缓存"
                    try StikJIT.resetCachedDDI(at: paths)
                    if request["hostBundlePath"] is String {
                        // The desktop cache and helper cache belong to different
                        // processes. Reset the second cache before reporting done.
                        SSStikDebugExecuteInHelper(request as? [String: Any] ?? [:])
                        return
                    }
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
                    stage = "准备设备 / 挂载 DDI"
                    let state = try prepare()
                    complete(["message": "设备准备完成；TXM/SPTM：" + (state.isTXMPresent.map { $0 ? "存在" : "不存在" } ?? "未知")])
                    return
                }
                if operation == "enablePID" {
                    stage = "验证容器进程"
                    guard let value = request["targetPID"] as? NSNumber,
                          value.int64Value > 0, value.int64Value <= Int64(Int32.max),
                          value.int32Value != getpid() else { throw Self.failure("容器目标 PID 无效或与辅助进程相同。") }
                    let script: StikJIT.Script
                    if let encoded = request["scriptData"] as? String, !encoded.isEmpty {
                        guard let data = Data(base64Encoded: encoded), data.count <= 1024 * 1024,
                              String(data: data, encoding: .utf8) != nil else { throw Self.failure("容器 JIT 脚本格式无效。") }
                        script = .customBase64(encoded)
                    } else { script = .universal }
                    stage = "为容器进程启用 JIT"
                    try StikJIT.enableJIT(targetPID: value.int32Value, pairingFile: pairing, ddiPaths: paths,
                        configuration: config, script: script, forceScript: false,
                        preparationProgress: reportStage, progress: progress)
                    complete(["message": "容器 JIT 调试流程已完成。"])
                    return
                }
                guard operation == "list" || operation == "enable" else { throw Self.failure("不支持的调试操作。") }
                stage = "连接调试隧道"
                progress(stage + "…")
                let remote = try RemoteDevice(pairing: file, config: config)
                let excluded = Set(request["excludedBundleIDs"] as? [String] ?? [])
                stage = "读取 App 列表"
                progress(stage + "…")
                let apps = try remote.debuggableApps().filter { !excluded.contains($0["bundleID"] ?? "") }
                if operation == "list" { complete(["apps": apps, "message": "已找到 \(apps.count) 个可调试 App。"]); return }
                guard operation == "enable", let bundleID = request["bundleID"] as? String,
                      apps.contains(where: { $0["bundleID"] == bundleID }) else {
                    throw Self.failure("目标 App 不在可调试列表中，或缺少 get-task-allow；不能调试当前二合一宿主。")
                }
                stage = "准备设备 / 挂载 DDI"
                _ = try prepare()
                stage = "启动目标 App"
                progress("启动目标 App…")
                let pid = try remote.launch(bundleID)
                guard pid > 0, pid != getpid() else { throw Self.failure("不能从当前进程为自身启用 JIT。") }
                stage = "启用 JIT"
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairing, ddiPaths: paths,
                    configuration: config, script: .universal,
                    forceScript: request["forceScript"] as? Bool ?? false,
                    preparationProgress: reportStage, progress: progress)
                complete(["message": "JIT 调试流程已完成。目标 App 是否能够执行 JIT，仍需在目标内验证。"])
            } catch {
                let detail = error as NSError
                complete(["error": "步骤：\(stage)\n\(detail.localizedDescription)\n错误标识：\(detail.domain) (\(detail.code))"])
            }
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
            guard let app = apps[index] else { continue }
            if let descriptor = StikAppMetadataReader.descriptor(from: app,
                item: { node, key in
                    guard plist_get_node_type(node) == PLIST_DICT else { return nil }
                    return plist_dict_get_item(node, key)
                }, string: { node in
                    guard plist_get_node_type(node) == PLIST_STRING else { return nil }
                    var value: UnsafeMutablePointer<CChar>?
                    plist_get_string_val(node, &value)
                    guard let value else { return nil }
                    defer { plist_mem_free(value) }
                    return String(validatingUTF8: value)
                }, boolean: { node in
                    switch plist_get_node_type(node) {
                    case PLIST_BOOLEAN:
                        var value: UInt8 = 0
                        plist_get_bool_val(node, &value)
                        return value != 0
                    case PLIST_INT:
                        var value: UInt64 = 0
                        plist_get_uint_val(node, &value)
                        return value != 0
                    default: return nil
                    }
                }) { result.append(descriptor) }
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
