import XCTest
@testable import ClaudeWidgetCore

final class EventMapperTests: XCTestCase {
    private func payload(_ extra: String = "") -> HookPayload {
        let json = #"{"session_id":"s1","cwd":"/tmp/proj"\#(extra)}"#.data(using: .utf8)!
        return HookPayload(json: json)!
    }

    func testPayloadRejectsMissingSessionId() {
        XCTAssertNil(HookPayload(json: #"{"cwd":"/tmp"}"#.data(using: .utf8)!))
        XCTAssertNil(HookPayload(json: "not json".data(using: .utf8)!))
    }

    func testSessionStartWritesReadyAndClearsWorkingSince() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 50, updatedAt: 60)
        let update = EventMapper.map(event: "SessionStart", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .ready)
        XCTAssertNil(s.workingSince)
        XCTAssertEqual(s.updatedAt, 100)
    }

    func testPromptSubmitStampsWorkingSinceOnNewStretch() {
        let prev = Session(sessionId: "s1", state: .waiting, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        let update = EventMapper.map(event: "UserPromptSubmit", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .working)
        XCTAssertEqual(s.workingSince, 100, "new working stretch re-stamps")
    }

    func testPreToolUsePreservesWorkingSinceWithinStretch() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        let update = EventMapper.map(event: "PreToolUse", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.workingSince, 10)
    }

    func testPermissionRequestMapsToNeedsYouWithToolNameAndCarriesWorkingSince() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        // Not a raw string literal here: a raw string's closing delimiter is `"`
        // immediately followed by N `#`s, so content can never end in a bare `"`
        // (adding more `#`s doesn't help — see EventMapper task report).
        let update = EventMapper.map(event: "PermissionRequest", payload: payload(",\"tool_name\":\"Bash\""), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .needsYou)
        XCTAssertEqual(s.message, "Bash")
        XCTAssertEqual(s.workingSince, 10, "carried so the app can read it at transitions")
    }

    func testNotificationMapsToNeedsYouWithMessage() {
        // Same raw-string caveat as testPermissionRequestMaps...: use an escaped literal.
        let update = EventMapper.map(event: "Notification", payload: payload(",\"message\":\"Claude is waiting for your input\""), previous: nil, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .needsYou)
        XCTAssertEqual(s.message, "Claude is waiting for your input")
    }

    func testStopMapsToWaitingAndCarriesWorkingSince() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        let update = EventMapper.map(event: "Stop", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.workingSince, 10)
    }

    func testSessionEndRemoves() {
        XCTAssertEqual(EventMapper.map(event: "SessionEnd", payload: payload(), previous: nil, now: 100),
                       .remove(sessionId: "s1"))
    }

    func testUnknownEventIgnored() {
        XCTAssertEqual(EventMapper.map(event: "PostToolBatch", payload: payload(), previous: nil, now: 100), .ignore)
    }

    func testContextTokensPreservedAcrossEvents() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", contextTokens: 12345, updatedAt: 20)
        let update = EventMapper.map(event: "PreToolUse", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.contextTokens, 12345)
    }

    func testSessionStartCapturesModelAndTitle() {
        let update = EventMapper.map(event: "SessionStart",
                                     payload: payload(",\"model\":\"claude-opus-4-8\",\"session_title\":\"My Task\""),
                                     previous: nil, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.model, "claude-opus-4-8")
        XCTAssertEqual(s.title, "My Task")
    }

    func testSessionStartOnCompactPreservesModelAndTitle() {
        // The model arrives only on the initial startup SessionStart. A later
        // SessionStart (compaction / resume / clear) omits it — it must not wipe
        // the model we already captured.
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj",
                           model: "claude-opus-4-8", title: "My Task", updatedAt: 60)
        let update = EventMapper.map(event: "SessionStart", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.model, "claude-opus-4-8", "compact SessionStart lacks model; keep the captured one")
        XCTAssertEqual(s.title, "My Task", "same for title")
    }
}
