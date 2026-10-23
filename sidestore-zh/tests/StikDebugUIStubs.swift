import Foundation
import SwiftUI
enum PairingProtocol { case lockdown, rppairing }
final class PairingFileManager {
    static let shared = PairingFileManager()
    var preferredProtocol: PairingProtocol? { nil }
    func hasPairingFile(for mode: PairingProtocol) -> Bool { false }
    func pairingFileURL(for mode: PairingProtocol) -> URL { URL(fileURLWithPath: "/unavailable") }
}
final class ConnectionConfig {
    static let shared = ConnectionConfig()
    var overrideTunnelPeerIp = ""
    var tunnelPeerIp: String?
}
var remotePairingPortCache: UInt16 = 49152
extension UserDefaults {
    var remotePairingPortOverride: Int { 0 }
    var isMinimuxerBackendHotswapEnabled: Bool { get { false } set {} }
}
extension Bundle {
    enum Info {
        static let activeBundleURL = Bundle.main.bundleURL
        static let activeBundleIdentifier = "com.kdt.livecontainer"
    }
}
struct PairingFileManagementView: View { var body: some View { EmptyView() } }
struct ConnectionConfigView: View { var body: some View { EmptyView() } }
struct WirelessPairView: View { var body: some View { EmptyView() } }
struct CacheManagementView: View { var body: some View { EmptyView() } }
extension UIColor { static let settingsBackground = UIColor.black }
