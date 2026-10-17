// Dependencies supplied by SideStore in the full application build.
// Compile the actual VPN UI/controller against the selected SDK before archiving.
import Foundation
import SwiftUI
extension Bundle { struct Info { static var activeBundle: Bundle { .main } } }
extension UserDefaults { var isMinimuxerBackendHotswapEnabled: Bool { get { false } set {} } }
extension UIColor { static var settingsBackground: UIColor { .black } }
struct WirelessPairView: View { var body: some View { EmptyView() } }
struct CacheManagementView: View { var body: some View { EmptyView() } }
