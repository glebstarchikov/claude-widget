import XCTest
@testable import ClaudeWidgetCore

/// Spawns the built `claude-widget-hook` (spec §11) with its home redirected by
/// `CFFIXED_USER_HOME` to a short temporary directory, so its state files and
/// approval socket live there, never in the real `~/.claude/claude-widget`.
/// A `FakeServer` plays the app at `<home>/.claude/claude-widget/run/approve.sock`.
final class HookProcessTests: XCTestCase {
    private var home = ""
    private let sessionId = "hooktest-\(UUID().uuidString.prefix(8))"

    private var widgetDir: String { home + "/.claude/claude-widget" }
    private var socketPath: String { widgetDir + "/run/approve.sock" }
    private var stateFile: String { widgetDir + "/state/\(sessionId).json" }

    /// `swift test` builds every target first (the hook included, measured), so
    /// the current hook sits next to the test bundle.
    private static var hookBinary: URL {
        Bundle(for: HookProcessTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("claude-widget-hook")
    }

    override func setUpWithError() throws {
        let hook = Self.hookBinary
        guard FileManager.default.isExecutableFile(atPath: hook.path) else {
            XCTFail("no hook binary at \(hook.path): run swift build first")
            throw CocoaError(.fileNoSuchFile)
        }

        home = "/tmp/cwh-\(UUID().uuidString.prefix(8))"
        XCTAssertLessThan(socketPath.utf8.count, 104)
        try FileManager.default.createDirectory(atPath: widgetDir + "/state", withIntermediateDirectories: true)

        // Prove the redirect before any test can touch the socket: SessionEnd removes
        // a file placed under the temporary home. Without the redirect it would look
        // in the real state directory, find nothing there, and change nothing.
        try Data(#"{"session_id":"\#(sessionId)","state":"ready","cwd":"/tmp/p","updated_at":1}"#.utf8)
            .write(to: URL(fileURLWithPath: stateFile))
        _ = try runHook("SessionEnd", ["session_id": sessionId, "cwd": "/tmp/p"])
        guard !FileManager.default.fileExists(atPath: stateFile) else {
            XCTFail("CFFIXED_USER_HOME did not redirect the hook's home; refusing to run against the real one")
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    override func tearDown() {
        if !home.isEmpty { try? FileManager.default.removeItem(atPath: home) }
    }

    // MARK: - Helpers

    private func permissionPayload(agentId: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["session_id": sessionId, "cwd": "/tmp/demo-project", "tool_name": "Bash",
                                      "tool_input": ["command": "npm test", "description": "Run the tests"]]
        if let agentId { payload["agent_id"] = agentId; payload["agent_type"] = "Explore" }
        return payload
    }

    private struct Run { let stdout: Data; let status: Int32; let elapsed: TimeInterval }

    private func runHook(_ event: String, _ payload: [String: Any]) throws -> Run {
        let process = Process()
        process.executableURL = Self.hookBinary
        process.arguments = [event]
        process.environment = ["CFFIXED_USER_HOME": home, "__CFBundleIdentifier": "com.example.owner"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let t0 = Date()
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(stdout: out, status: process.terminationStatus, elapsed: Date().timeIntervalSince(t0))
    }

    /// Runs a PermissionRequest against a fake app playing `steps`.
    private func ask(_ steps: [FakeServer.Step], agentId: String? = nil) throws -> (Run, ApprovalRequest?) {
        let server = try FakeServer(steps: steps, path: socketPath)
        let run = try runHook("PermissionRequest", permissionPayload(agentId: agentId))
        server.finish()
        return (run, server.received)
    }

    private func state() throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: stateFile)))
    }

    private let ack = FakeServer.Step.write("{\"ack\":true}\n")

    // MARK: - No app

    func testNoSocketAddsNoDelayAndPrintsNothing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        // Process launch dominates either way, so compare against an event that never
        // touches the socket: what PermissionRequest adds is the connect attempt.
        var baseline = TimeInterval.infinity, permission = TimeInterval.infinity
        for _ in 0..<3 {
            baseline = min(baseline, try runHook("PreToolUse", permissionPayload()).elapsed)
            let run = try runHook("PermissionRequest", permissionPayload())
            XCTAssertEqual(run.status, 0)
            XCTAssertEqual(run.stdout, Data(), "no output: Claude Code shows its own prompt")
            permission = min(permission, run.elapsed)
        }
        XCTAssertLessThan(permission - baseline, 0.05, "spec §11: < 50 ms added with the app not running")
        XCTAssertEqual(try state().state, .needsYou, "the state file is still written")
    }

    func testSocketThatNeverRepliesFallsThroughAfterTheAckTimeout() throws {
        let (run, _) = try ask([.sleep(1.0)])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, Data())
        XCTAssertGreaterThanOrEqual(run.elapsed, WidgetConstants.approvalAckTimeout)
        XCTAssertLessThan(run.elapsed, 0.95, "gave up at the 0.5 s ack deadline, not when the server hung up")
        XCTAssertEqual(try state().state, .needsYou)
    }

    // MARK: - Answers

    func testAckThenAllowPrintsTheExactAllowLine() throws {
        let (run, received) = try ask([ack, .write("{\"decision\":\"allow\"}\n")])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, Data((HookDecision.allowJSON + "\n").utf8))
        XCTAssertEqual(received?.sessionId, sessionId)
        XCTAssertEqual(received?.toolName, "Bash")
        XCTAssertEqual(received?.ownerBundleId, "com.example.owner")
        XCTAssertEqual(received?.toolInput, #"{"command":"npm test","description":"Run the tests"}"#)
    }

    func testAckThenDenyPrintsTheExactDenyLine() throws {
        let (run, _) = try ask([ack, .write("{\"decision\":\"deny\"}\n")])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, Data((HookDecision.denyJSON + "\n").utf8))
    }

    func testAckThenClosePrintsNothing() throws {
        let (run, _) = try ask([ack, .close])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, Data())
    }

    func testAckThenPassPrintsNothing() throws {
        let (run, _) = try ask([ack, .write("{\"pass\":true}\n")])
        XCTAssertEqual(run.stdout, Data())
    }

    // MARK: - Session state after a notch answer (final review I4)

    func testAllowFromTheNotchPutsTheSessionBackToWorking() throws {
        _ = try ask([ack, .write("{\"decision\":\"allow\"}\n")])
        let session = try state()
        XCTAssertEqual(session.state, .working, "not 'needs you' until Claude's next hook event")
        XCTAssertNil(session.message)
        XCTAssertEqual(session.tool, "Bash: npm test")
        XCTAssertEqual(session.ownerBundleId, "com.example.owner")
        XCTAssertNotNil(session.workingSince)
    }

    func testDenyFromTheNotchPutsTheSessionBackToWorking() throws {
        _ = try ask([ack, .write("{\"decision\":\"deny\"}\n")])
        XCTAssertEqual(try state().state, .working)
    }

    func testNoDecisionLeavesTheSessionNeedingYou() throws {
        _ = try ask([ack, .close])
        XCTAssertEqual(try state().state, .needsYou, "Claude's own prompt is up: it still needs you")
        _ = try ask([.write("{\"pass\":true}\n")])
        XCTAssertEqual(try state().state, .needsYou)
    }

    func testSubagentAnswerLeavesTheParentSessionAlone() throws {
        let parent = Session(sessionId: sessionId, state: .needsYou, cwd: "/tmp/demo-project", message: "Notification",
                             updatedAt: 1)
        let original = try JSONEncoder().encode(parent)
        try original.write(to: URL(fileURLWithPath: stateFile))
        let (run, received) = try ask([ack, .write("{\"decision\":\"allow\"}\n")], agentId: "agent-1")
        XCTAssertEqual(run.stdout, Data((HookDecision.allowJSON + "\n").utf8))
        XCTAssertEqual(received?.agentId, "agent-1")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stateFile)), original,
                       "only main-loop requests write the session back")
    }
}
