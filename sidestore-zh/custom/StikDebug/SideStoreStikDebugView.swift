import SwiftUI
import Darwin

struct SideStoreStikDebugView: View {
    var initialBundleID: String? = nil
    var initialName: String? = nil
    var body: some View {
        Group {
            if #available(iOS 17.4, *) { StikDebugToolsView(initialBundleID: initialBundleID, initialName: initialName) }
            else { Text("StikDebug JIT 需要 iOS 17.4 或更新版本。请继续使用原有侧载和刷新功能。") }
        }
        .navigationTitle("StikDebug · 实验性")
    }
}

@available(iOS 17.4, *)
@MainActor
private final class StikDebugModel: NSObject, ObservableObject {
    @Published var busy = false
    @Published var status = "尚未准备"
    @Published var error: String?
    @Published var apps: [[String: String]] = []
    @Published var containers: [[String: String]] = []
    @Published var containerError: String?
    @Published var logs: [String] = []
    private var library: UnsafeMutableRawPointer?
    private var core: NSObject?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    func invalidate() {
        guard !busy else { return }
        status = "配对或连接配置可能已变化，请重新准备。"
        apps = []
    }

    func run(_ operation: String, bundleID: String? = nil, forceScript: Bool = false) {
        guard !busy else { return }
        error = nil
        do {
            if core == nil {
                let path = Bundle.Info.activeBundleURL.appendingPathComponent("Frameworks/SideStoreStikDebugCore.framework/SideStoreStikDebugCore").path
                library = dlopen(path, RTLD_NOW | RTLD_LOCAL)
                guard library != nil else {
                    throw failure("无法加载内置 StikJIT 核心：" + (dlerror().map { String(cString: $0) } ?? "未知错误"))
                }
                guard let type = NSClassFromString("SSStikDebugCore") as? NSObject.Type,
                      let shared = type.perform(NSSelectorFromString("shared"))?.takeUnretainedValue() as? NSObject,
                      shared.responds(to: NSSelectorFromString("execute:")) else { throw failure("StikJIT 核心接口不完整，请重新安装本次构建。") }
                core = shared
            }
            let pairing = pairingURL()
            if operation != "reset", !FileManager.default.isReadableFile(atPath: pairing.path) {
                throw failure("此入口需要 Remote Pairing（RPPairing）文件。请先导入对应文件，或在支持的系统上使用无线配对；旧 Lockdown 文件不能替代它。")
            }
            let connection = ConnectionConfig.shared
            let address = connection.overrideTunnelPeerIp.isEmpty ? (connection.tunnelPeerIp ?? "10.7.0.1") : connection.overrideTunnelPeerIp
            let port = UserDefaults.standard.remotePairingPortOverride
            let effectivePort = port > 0 ? port : Int(remotePairingPortCache)
            try saveConnection(address: address, port: effectivePort)
            var request: [String: Any] = ["operation": operation, "reply": self,
                "hostBundlePath": Bundle.Info.activeBundleURL.path,
                "pairingPath": pairing.path, "address": address, "port": effectivePort,
                "forceScript": forceScript, "excludedBundleIDs": [Bundle.Info.activeBundleIdentifier, "com.SideStore.SideStore"]]
            if let bundleID { request["bundleID"] = bundleID }
            busy = true
            status = "正在处理…"
            logs = []
            if operation == "reset" { apps = [] }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "StikDebug JIT") { [weak self] in
                guard let self else { return }
                self.progress("系统后台执行时间已到，请返回二合一 App。调试操作尚未报告完成。")
                self.endBackgroundTask()
            }
            // Keep the already verified desktop-App path. Only container PID
            // requests from LiveContainer use the separate helper process.
            _ = core?.perform(NSSelectorFromString("execute:"), with: request as NSDictionary)
        } catch { self.error = error.localizedDescription; status = "未完成" }
    }

    private func hostHome() throws -> String {
        guard let value = getenv("LC_HOME_PATH") else { throw failure("当前不是 LiveContainer 二合一环境。") }
        return String(cString: value)
    }

    private func saveConnection(address: String, port: Int) throws {
        let url = URL(fileURLWithPath: try hostHome()).appendingPathComponent("Documents/SideStore/Library/Preferences/SSBuiltInJITConnection.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["address": address, "port": port], format: .binary, options: 0).write(to: url, options: .atomic)
    }

    func loadContainers() {
        containerError = nil
        do {
            if core == nil {
                let path = Bundle.Info.activeBundleURL.appendingPathComponent("Frameworks/SideStoreStikDebugCore.framework/SideStoreStikDebugCore").path
                library = dlopen(path, RTLD_NOW | RTLD_LOCAL)
                if let type = NSClassFromString("SSStikDebugCore") as? NSObject.Type {
                    core = type.perform(NSSelectorFromString("shared"))?.takeUnretainedValue() as? NSObject
                }
            }
            guard let core, core.responds(to: NSSelectorFromString("containerApps:")),
                  let result = core.perform(NSSelectorFromString("containerApps:"), with: ["hostHome": try hostHome()] as NSDictionary)?.takeUnretainedValue() as? NSDictionary else {
                throw failure("无法读取当前 LiveContainer 的容器列表。")
            }
            if let message = result["error"] as? String { throw failure(message) }
            containers = result["apps"] as? [[String: String]] ?? []
        } catch { containers = []; containerError = error.localizedDescription }
    }

    func launchContainer(_ app: [String: String]) {
        guard !busy else { return }
        do {
            let connection = ConnectionConfig.shared
            let address = connection.overrideTunnelPeerIp.isEmpty ? (connection.tunnelPeerIp ?? "10.7.0.1") : connection.overrideTunnelPeerIp
            let override = UserDefaults.standard.remotePairingPortOverride
            try saveConnection(address: address, port: override > 0 ? override : Int(remotePairingPortCache))
            var request = app
            request["hostHome"] = try hostHome()
            guard let core, let result = core.perform(NSSelectorFromString("launchContainer:"), with: request as NSDictionary)?.takeUnretainedValue() as? NSDictionary else {
                throw failure("缺少容器启动接口，请安装完整更新包。")
            }
            if let message = result["error"] as? String { throw failure(message) }
        } catch { self.error = error.localizedDescription }
    }

    func pairingURL() -> URL {
        // StikJIT opens an RpPairingFileHandle; never feed it the signer's
        // preferred Lockdown file or silently change SideStore's protocol.
        PairingFileManager.shared.pairingFileURL(for: .rppairing)
    }

    @objc func progress(_ text: String) {
        status = text
        logs.append(text)
        if logs.count > 120 { logs.removeFirst(logs.count - 120) }
    }

    @objc func complete(_ reply: NSDictionary) {
        busy = false
        endBackgroundTask()
        if let message = reply["error"] as? String {
            error = message
            status = "未完成"
        } else {
            status = reply["message"] as? String ?? "处理完成"
            if let apps = reply["apps"] as? [[String: String]] { self.apps = apps }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "SideStore.StikDebug", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

@available(iOS 17.4, *)
private struct StikDebugToolsView: View {
    let initialBundleID: String?
    let initialName: String?
    @State private var didStartTarget = false
    @StateObject private var model = StikDebugModel()
    @AppStorage("SSStikDebugForceScript") private var forceScript = false
    @State private var selectedApp: StikTarget?
    @State private var confirmReset = false
    @State private var query = ""

    private func matches(_ app: [String: String]) -> Bool {
        query.isEmpty || (app["name"] ?? "").localizedCaseInsensitiveContains(query) ||
            (app["bundleID"] ?? "").localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        SwiftUI.Form {
            if let initialName { Section(header: Text("当前目标")) { Text(initialName) } }
            Section(header: Text("使用条件"), footer: Text("目标需有 get-task-allow，并启用开发者模式。iOS 26 的目标 App 还需支持 universal.js 协议。容器 App 会切换到 LiveContainer，以实际 LiveProcess PID 启用内置 JIT。")) {
                Text("iOS 17.4+ · 先连接外置 LocalDevVPN")
                Text("内置 StikJIT；容器 JIT 复用现有 LiveProcess，不新增 VPN 或应用扩展。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section(header: Text("配对与连接")) {
                NavigationLink("配对文件管理", destination: PairingFileManagementView())
                if #available(iOS 26.0, *) { NavigationLink("无线配对", destination: WirelessPairView()) }
                NavigationLink("连接配置", destination: ConnectionConfigView())
                Text("需要 Remote Pairing：" + model.pairingURL().lastPathComponent).font(.footnote)
            }
            .disabled(model.busy)
            Section(header: Text("搜索应用")) {
                TextField("名称或 Bundle ID", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section(header: Text("LiveContainer 容器 App"), footer: Text("只列出当前主实例可访问的可见、未锁定 App。选择后会切换到 LiveContainer，通过内置 JIT 启动。")) {
                SwiftUI.Button("重新读取容器 App") { model.loadContainers() }
                if let error = model.containerError { Text(error).foregroundColor(.red) }
                ForEach(model.containers.filter(matches), id: \.self) { app in
                    SwiftUI.Button {
                        selectedApp = StikTarget(id: (app["folderName"] ?? "") + (app["shared"] ?? ""), name: app["name"] ?? "App", container: app)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app["name"] ?? "App")
                            Text(app["bundleID"] ?? "").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }.disabled(model.busy)
            Section(header: Text("JIT 准备")) {
                SwiftUI.Button("准备设备 / 挂载 DDI") { model.run("prepare") }
                SwiftUI.Button("读取可调试 App") { model.run("list") }
                Toggle("强制使用 universal 脚本", isOn: $forceScript)
                Text(model.status).font(.footnote).textSelection(.enabled)
                if model.busy { ProgressView() }
                if let error = model.error { Text(error).foregroundColor(.red).textSelection(.enabled) }
            }
            .disabled(model.busy)
            if !model.apps.isEmpty {
                Section(header: Text("选择 App 启用 JIT"), footer: Text("只列出设备报告带有 get-task-allow 的 App。目标可能被切换到前台；若调试尚未结束，可返回本 App 查看进度。")) {
                    ForEach(model.apps.filter(matches), id: \.self) { app in
                        SwiftUI.Button {
                            if let id = app["bundleID"] { selectedApp = StikTarget(id: id, name: app["name"] ?? id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app["name"] ?? "App")
                                Text(app["bundleID"] ?? "").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }.disabled(model.busy)
            }
            if !model.logs.isEmpty {
                Section(header: Text("本次进度")) {
                    Text(model.logs.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section(header: Text("恢复与来源"), footer: Text("此功能是非官方实验性集成，真实错误会显示在页面。重置只清理本功能的 DDI 缓存，不删除配对文件。")) {
                SwiftUI.Button("重置开发者磁盘镜像缓存", role: .destructive) { confirmReset = true }.disabled(model.busy)
                Link("StikDebug 源码 · AGPL-3.0", destination: URL(string: "https://github.com/StikDebug/StikDebug")!)
                Link("StikJIT 核心与集成说明 · MPL-2.0", destination: URL(string: "https://github.com/StikDebug/StikJIT")!)
            }
        }
        .onAppear {
            model.loadContainers()
            if let initialBundleID, !didStartTarget {
                didStartTarget = true
                if initialBundleID == Bundle.Info.activeBundleIdentifier {
                    model.status = "这是当前二合一宿主，请在容器 App 列表中选择要启动的 App。"
                } else { model.run("enable", bundleID: initialBundleID, forceScript: forceScript) }
            } else { model.invalidate() }
        }
        .alert(item: $selectedApp) { target in
            Alert(title: Text("为 \(target.name) 启用 JIT？"), message: Text("会启动目标并连接调试器。此过程不会为缺少权限或不兼容协议的 App 补充 JIT 支持。"), primaryButton: .default(Text("启用")) {
                if let container = target.container { model.launchContainer(container) }
                else { model.run("enable", bundleID: target.id, forceScript: forceScript) }
            }, secondaryButton: .cancel(Text("取消")))
        }
        .alert("重置 DDI 缓存？", isPresented: $confirmReset) {
            SwiftUI.Button("重置", role: .destructive) { model.run("reset") }
            SwiftUI.Button("取消", role: .cancel) { }
        }
    }
}

private struct StikTarget: Identifiable { let id: String; let name: String; var container: [String: String]? = nil }
