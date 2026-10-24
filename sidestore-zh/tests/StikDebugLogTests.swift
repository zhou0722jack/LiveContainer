import Foundation

@main
struct StikDebugLogTests {
    @MainActor static func main() {
        let started = Date(timeIntervalSince1970: 100)
        let first = StikDebugLogSession(name: "Example", bundleID: "test.resigned.app", limit: 3, startedAt: started)
        first.update("Connecting")
        first.update("Preparing DDI")
        first.update("Attaching")
        first.finish(message: "stage: debugger; domain: test; code: 7", error: true)
        assert(first.finished && first.failed && first.entries.count == 3 && first.omittedCount == 1)
        assert(first.text.contains("test.resigned.app") && first.text.contains("较早的 1 条日志已省略"))
        assert(first.text.contains("stage: debugger; domain: test; code: 7"))
        let frozen = first.text
        first.update("Late progress")
        first.finish(message: "Late success")
        assert(first.text == frozen, "A terminal error must not become a late success")
        let second = StikDebugLogSession(name: "Other", bundleID: "test.other.app")
        second.update("Started")
        second.finish(message: "Done")
        assert(second.finished && !second.failed)
        assert(first.text == frozen && second.id != first.id)
        assert(!second.text.contains("code: 7"), "Old logs must not leak into another task")

        second.notePresentationIssue("系统拒绝画中画")
        assert(second.finished && !second.failed && second.text.contains("系统拒绝画中画"))
        assert(first.text == frozen)
        print("PASS: copyable terminal errors, task isolation, bounded logs and PiP/JIT outcome separation")
    }
}
