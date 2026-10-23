import Foundation

private indirect enum Metadata {
    case dictionary([String: Metadata])
    case string(String)
    case boolean(Bool)
    case integer(Int)
    case opaque
}

private func decode(_ app: Metadata) -> [String: String]? {
    StikAppMetadataReader.descriptor(from: app, item: { node, key in
        guard case .dictionary(let values) = node else { return nil }
        return values[key]
    }, string: { node in
        guard case .string(let value) = node else { return nil }
        return value
    }, boolean: { node in
        switch node {
        case .boolean(let value): return value
        case .integer(let value): return value != 0
        default: return nil
        }
    })
}

private func record(_ permission: Metadata = .boolean(true), identifier: Metadata = .string("test.app"),
                    displayName: Metadata = .string("测试 App"), extra: Metadata = .opaque) -> Metadata {
    .dictionary(["CFBundleIdentifier": identifier, "CFBundleDisplayName": displayName,
                 "Entitlements": .dictionary(["get-task-allow": permission]),
                 "UnsupportedDeviceMetadata": extra])
}

@main
private enum Tests {
    static func main() {
        // Unknown/nested opaque metadata must not prevent the required fields
        // being read. It must never be visited or serialized by the reader.
        let app = record(extra: .dictionary(["Unserializable": .opaque]))
        assert(decode(app) == ["name": "测试 App", "bundleID": "test.app"])
        var keys: [String] = []
        let direct = StikAppMetadataReader.descriptor(from: app, item: { node, key in
            keys.append(key)
            guard case .dictionary(let values) = node else { return nil }
            return values[key]
        }, string: { node in
            guard case .string(let value) = node else { return nil }; return value
        }, boolean: { node in
            guard case .boolean(let value) = node else { return nil }; return value
        })
        assert(direct != nil)
        assert(!keys.contains("UnsupportedDeviceMetadata"))
        // Missing, invalid or denied debugging permissions never become targets.
        assert(decode(record(.boolean(false))) == nil)
        assert(decode(record(.string("true"))) == nil)
        assert(decode(record(.opaque)) == nil)
        assert(decode(.dictionary(["CFBundleIdentifier": .string("unentitled.app")])) == nil)
        assert(decode(.opaque) == nil)
        assert(decode(record(identifier: .opaque)) == nil)
        assert(decode(record(identifier: .string(""))) == nil)
        assert(decode(record(.integer(1))) != nil)
        assert(decode(record(.integer(0))) == nil)
        // Invalid optional names fall back to a known string or the identifier.
        assert(decode(record(displayName: .opaque))?["name"] == "test.app")
        assert(decode(record(displayName: .string("")))?["name"] == "test.app")
        let fallback = Metadata.dictionary(["CFBundleIdentifier": .string("fallback.app"),
            "CFBundleName": .string("Fallback"), "Entitlements": .dictionary(["get-task-allow": .boolean(true)])])
        assert(decode(fallback)?["name"] == "Fallback")
        // An invalid sibling cannot abort the complete listing.
        let batch = [Metadata.opaque, record(identifier: .opaque), app, fallback].compactMap(decode)
        assert(batch.count == 2)
        print("PASS: Stik app metadata regression checks")
    }
}
