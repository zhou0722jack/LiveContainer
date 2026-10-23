// Read only the app-list fields needed for JIT. Never serialize unrelated
// installation-proxy metadata through Foundation's property-list decoder.
enum StikAppMetadataReader {
    static func descriptor<Node>(
        from app: Node,
        item: (Node, String) -> Node?,
        string: (Node) -> String?,
        boolean: (Node) -> Bool?
    ) -> [String: String]? {
        guard let entitlements = item(app, "Entitlements"),
              let permission = item(entitlements, "get-task-allow"),
              boolean(permission) == true,
              let identifierNode = item(app, "CFBundleIdentifier"),
              let identifier = string(identifierNode), !identifier.isEmpty else { return nil }
        let displayName = item(app, "CFBundleDisplayName").flatMap(string)
        let bundleName = item(app, "CFBundleName").flatMap(string)
        let name = [displayName, bundleName].compactMap { $0 }.first { !$0.isEmpty } ?? identifier
        return ["name": name, "bundleID": identifier]
    }
}
