// Isolated SDK check for the actual minimal controller; full app archives remain required.
import UIKit
import SwiftUI
import CoreData

func debugLog(_ message: String) {}
class SourcesViewController: UIViewController { var deepLinkSourceURL: URL? }
enum AppDelegate {
    static let importAppDeepLinkNotification = Notification.Name("Import")
    static let addSourceDeepLinkNotification = Notification.Name("Source")
    static let importAppDeepLinkURLKey = "url"
    static let addSourceDeepLinkURLKey = "url"
}
enum ToastView { static let openErrorLogNotification = Notification.Name("Error") }
enum DatabaseManager {
    static let shared = State()
    class State { let viewContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); let isStarted = true }
}
class InstalledApp {
    var name = "App"
    var expirationDate = Date()
    static func fetchActiveApps(in context: NSManagedObjectContext) -> [InstalledApp] { [] }
    static func fetchAppsForRefreshingAll(in context: NSManagedObjectContext) -> [InstalledApp] { [] }
}
class RefreshGroup {
    let progress = Progress(totalUnitCount: 100)
    var completionHandler: (([String: Result<InstalledApp, Error>]) -> Void)?
}
enum InstallTarget { case url(URL) }
class AppManager {
    static let shared = AppManager()
    func install(_ target: InstallTarget, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup { RefreshGroup() }
    func refresh(_ targets: [InstalledApp], presentingViewController: UIViewController?) -> RefreshGroup { RefreshGroup() }
}
class AuthManager {
    static let shared = AuthManager()
    var currentAppleID: String? { nil }
    var isAuthenticated: Bool { false }
    func signOut() async {}
    func signIn(presentingViewController: UIViewController?) async throws {}
}
enum InstallAppDialog {
    static func present(ipaURL: URL, from: UIViewController, onConfirm: @escaping () -> Void) {}
}
struct PairingFileManagementView: View { var body: some View { EmptyView() } }
struct ConnectionConfigView: View { var body: some View { EmptyView() } }
struct AnisetteServersView: View { var body: some View { EmptyView() } }
extension Bundle { enum Info { static let activeBundle = Bundle.main } }
