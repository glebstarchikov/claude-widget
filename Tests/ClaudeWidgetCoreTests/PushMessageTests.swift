import XCTest
@testable import ClaudeWidgetCore

final class PushMessageTests: XCTestCase {
    private func session(cwd: String, message: String? = nil, tool: String? = nil) -> Session {
        Session(sessionId: "s1", state: .needsYou, cwd: cwd, message: message, tool: tool, updatedAt: 0)
    }

    func testNeedsYouPayload() {
        let p = PushMessage.from(.needsYou(session(cwd: "/Users/x/claude-widget")))
        XCTAssertEqual(p.title, "Claude needs you")
        XCTAssertEqual(p.body, "claude-widget")
        XCTAssertEqual(p.priority, .urgent)
        XCTAssertEqual(p.tags, ["eyes"])
    }

    func testFinishedPayload() {
        let p = PushMessage.from(.finished(session(cwd: "/Users/x/claude-widget"), duration: 260))
        XCTAssertEqual(p.title, "Finished")
        XCTAssertEqual(p.body, "claude-widget · 4m 20s")
        XCTAssertEqual(p.priority, .high)
        XCTAssertEqual(p.tags, ["white_check_mark"])
    }

    // Privacy invariant: sensitive fields must never reach the body.
    func testBodyNeverLeaksMessageOrTool() {
        let s = session(cwd: "/Users/x/secret-proj", message: "rm -rf /tmp/x", tool: "Bash: rm -rf /tmp/x")
        let p = PushMessage.from(.needsYou(s))
        XCTAssertEqual(p.body, "secret-proj")
        XCTAssertFalse(p.body.contains("rm -rf"))
        XCTAssertFalse(p.body.contains("Bash"))
    }
}
