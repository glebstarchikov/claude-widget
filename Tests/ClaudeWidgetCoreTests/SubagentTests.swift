import XCTest
@testable import ClaudeWidgetCore

final class SubagentMappingTests: XCTestCase {
    private func payload(_ extra: String = "") -> HookPayload {
        HookPayload(json: #"{"session_id":"s1","cwd":"/tmp/proj"\#(extra)}"#.data(using: .utf8)!)!
    }

    func testAgentIdParsedAndEmptyTreatedAsMainLoop() {
        XCTAssertEqual(payload(#","agent_id":"a9""#).agentId, "a9")
        XCTAssertNil(payload(#","agent_id":"""#).agentId, "empty agent_id → main loop, not a subagent")
        XCTAssertNil(payload().agentId)
    }

    func testToolDisplayFromToolInput() {
        let bash = payload(#","tool_name":"Bash","tool_input":{"command":"npm test"}"#)
        XCTAssertEqual(bash.toolDisplay, "Bash: npm test")
        let edit = payload(#","tool_name":"Edit","tool_input":{"file_path":"/a/b/page.tsx"}"#)
        XCTAssertEqual(edit.toolDisplay, "Edit page.tsx")
        let bare = payload(#","tool_name":"WebSearch""#)
        XCTAssertEqual(bare.toolDisplay, "WebSearch", "unknown tool falls back to its name")
    }

    func testSubagentStartWritesRecord() {
        let p = payload(#","agent_id":"a9","agent_type":"code-reviewer""#)
        let update = EventMapper.mapSubagent(event: "SubagentStart", payload: p, previous: nil, now: 100)
        guard case .write(let rec) = update else { return XCTFail("expected write") }
        XCTAssertEqual(rec.sessionId, "s1")
        XCTAssertEqual(rec.agentId, "a9")
        XCTAssertEqual(rec.agentType, "code-reviewer")
        XCTAssertNil(rec.tool)
        XCTAssertEqual(rec.updatedAt, 100)
    }

    func testSubagentToolCapturedAndTypePreserved() {
        let prev = SubagentRecord(sessionId: "s1", agentId: "a9", agentType: "general-purpose", updatedAt: 50)
        let p = payload(#","agent_id":"a9","tool_name":"Bash","tool_input":{"command":"grep foo"}"#)
        let update = EventMapper.mapSubagent(event: "PreToolUse", payload: p, previous: prev, now: 100)
        guard case .write(let rec) = update else { return XCTFail("expected write") }
        XCTAssertEqual(rec.tool, "Bash: grep foo")
        XCTAssertEqual(rec.agentType, "general-purpose", "type carried from the previous record")
    }

    func testSubagentStopRemoves() {
        let p = payload(#","agent_id":"a9""#)
        XCTAssertEqual(EventMapper.mapSubagent(event: "SubagentStop", payload: p, previous: nil, now: 100),
                       .remove(agentId: "a9"))
    }

    func testMapSubagentIgnoresWithoutAgentId() {
        XCTAssertEqual(EventMapper.mapSubagent(event: "SubagentStart", payload: payload(), previous: nil, now: 100), .ignore)
    }

    func testSessionStartCapturesModelAndTitle() {
        let p = payload(#","model":"opus","session_title":"fix auth""#)
        let update = EventMapper.map(event: "SessionStart", payload: p, previous: nil, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.model, "opus")
        XCTAssertEqual(s.title, "fix auth")
    }

    func testPreToolUseCapturesToolAndPreservesModel() {
        let prev = Session(sessionId: "s1", state: .ready, cwd: "/tmp/proj", model: "sonnet", updatedAt: 50)
        let p = payload(#","tool_name":"Bash","tool_input":{"command":"ls"}"#)
        let update = EventMapper.map(event: "PreToolUse", payload: p, previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.tool, "Bash: ls")
        XCTAssertEqual(s.model, "sonnet", "model preserved across the transition")
    }

    func testStopClearsTool() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", tool: "Bash: ls", updatedAt: 50)
        let update = EventMapper.map(event: "Stop", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertNil(s.tool)
    }
}

final class StateStoreSubagentTests: XCTestCase {
    var dir: URL!
    var store: StateStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-sub-\(UUID().uuidString)", isDirectory: true)
        store = StateStore(directory: dir)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func session(_ id: String, updatedAt: Double) -> Session {
        Session(sessionId: id, state: .working, cwd: "/tmp/\(id)", updatedAt: updatedAt)
    }
    private func record(_ agentId: String, session: String, type: String, updatedAt: Double) -> SubagentRecord {
        SubagentRecord(sessionId: session, agentId: agentId, agentType: type, updatedAt: updatedAt)
    }

    func testSubagentWriteReadRemove() throws {
        let r = record("a1", session: "s1", type: "Explore", updatedAt: 100)
        try store.applySubagent(.write(r))
        XCTAssertEqual(store.readSubagent(agentId: "a1"), r)
        try store.applySubagent(.remove(agentId: "a1"))
        XCTAssertNil(store.readSubagent(agentId: "a1"))
    }

    func testLoadAllAttachesSubagentsToTheirSession() throws {
        try store.apply(.write(session("s1", updatedAt: 200)))
        try store.apply(.write(session("s2", updatedAt: 100)))
        try store.applySubagent(.write(record("a1", session: "s1", type: "code-reviewer", updatedAt: 210)))
        try store.applySubagent(.write(record("a2", session: "s1", type: "general-purpose", updatedAt: 220)))
        try store.applySubagent(.write(record("a3", session: "s2", type: "Explore", updatedAt: 110)))

        let sessions = store.loadAll(now: 300)
        let s1 = try XCTUnwrap(sessions.first { $0.sessionId == "s1" })
        let s2 = try XCTUnwrap(sessions.first { $0.sessionId == "s2" })
        XCTAssertEqual(s1.subagents.map(\.agentId), ["a2", "a1"], "s1 has both, newest first")
        XCTAssertEqual(s2.subagents.map(\.agentType), ["Explore"])
    }

    func testOrphanSubagentNotAttachedAndStaleGCd() throws {
        let now: Double = 1_000_000
        try store.apply(.write(session("s1", updatedAt: now - 60)))                             // fresh session
        try store.applySubagent(.write(record("orphan", session: "gone", type: "x", updatedAt: now - 60)))  // fresh, no parent
        try store.applySubagent(.write(record("stale", session: "s1", type: "x", updatedAt: 0)))            // older than 4h

        let sessions = store.loadAll(now: now)
        XCTAssertEqual(sessions.first { $0.sessionId == "s1" }?.subagents.count, 0,
                       "orphan belongs to no live session; stale is GC'd")
        XCTAssertNil(store.readSubagent(agentId: "stale"), "stale subagent file deleted")
    }
}
