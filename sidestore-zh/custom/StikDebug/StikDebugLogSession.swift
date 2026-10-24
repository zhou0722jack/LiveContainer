import Foundation
import Combine

// Keep each task's progress and terminal result together for copying.
@MainActor
final class StikDebugLogSession: ObservableObject, Identifiable {
    let id: UUID
    let name: String
    let bundleID: String?
    let startedAt: Date
    private let limit: Int
    @Published private(set) var entries: [String] = []
    @Published private(set) var status = "准备中"
    @Published private(set) var finished = false
    @Published private(set) var failed = false
    private(set) var omittedCount = 0

    init(name: String, bundleID: String? = nil, limit: Int = 2000, id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.limit = max(1, limit)
        self.startedAt = startedAt
    }

    func append(_ message: String, at date: Date = Date()) {
        guard !finished else { return }
        let stamp = ISO8601DateFormatter().string(from: date)
        entries.append("[\(stamp)] \(message)")
        if entries.count > limit {
            let excess = entries.count - limit
            entries.removeFirst(excess)
            omittedCount += excess
        }
    }

    func update(_ message: String) {
        guard !finished else { return }
        status = message
        append(message)
    }

    func finish(message: String, error: Bool = false) {
        guard !finished else { return }
        status = error ? "未完成" : "已完成"
        failed = error
        append((error ? "失败：" : "完成：") + message)
        finished = true
    }

    var text: String {
        var header = ["JIT 日志", "目标：" + name]
        if let bundleID { header.append("Bundle ID：" + bundleID) }
        header.append("开始：" + ISO8601DateFormatter().string(from: startedAt))
        header.append("状态：" + status)
        if omittedCount > 0 { header.append("较早的 \(omittedCount) 条日志已省略。") }
        return header.joined(separator: "\n") + "\n\n" + entries.joined(separator: "\n")
    }
}
