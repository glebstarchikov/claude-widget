import XCTest
@testable import ClaudeWidgetCore

/// Scripted stand-in for the app: accepts one connection, reads the request line, plays the steps.
private final class FakeServer {
    enum Step { case write(String), sleep(TimeInterval), close }

    let path: String
    private let dir: String
    private let listenFD: Int32
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _received: ApprovalRequest?
    var received: ApprovalRequest? { lock.lock(); defer { lock.unlock() }; return _received }

    init(steps: [Step]) throws {
        dir = "/tmp/cw-\(UUID().uuidString.prefix(8))"
        path = dir + "/a.sock"
        precondition(path.utf8.count < 104)
        listenFD = try UnixSocket.listen(path: path)
        let fd = listenFD
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            guard let conn = UnixSocket.accept(fd) else { return }
            defer { UnixSocket.close(conn) }
            if let line = LineReader(fd: conn).next(timeout: 2) {
                lock.lock(); _received = ApprovalWire.decodeRequest(line); lock.unlock()
            }
            for step in steps {
                switch step {
                case .write(let s): _ = UnixSocket.write(conn, Data(s.utf8))
                case .sleep(let t): Thread.sleep(forTimeInterval: t)
                case .close: return
                }
            }
        }
    }

    func finish() {
        _ = done.wait(timeout: .now() + 3)
        UnixSocket.close(listenFD)
        try? FileManager.default.removeItem(atPath: dir)
    }
}

final class ApprovalClientTests: XCTestCase {
    private func req() -> ApprovalRequest {
        ApprovalRequest(id: "r1", sessionId: "s1", agentId: nil, cwd: "/tmp/p", toolName: "Bash",
                        toolDisplay: "npm test", toolInput: #"{"command":"npm test"}"#,
                        toolInputTruncated: false, ownerBundleId: "com.apple.Terminal")
    }

    private func tempPath() -> String {
        let p = "/tmp/cw-\(UUID().uuidString.prefix(8))/a.sock"
        XCTAssertLessThan(p.utf8.count, 104)
        return p
    }

    private func run(_ steps: [FakeServer.Step], ack: TimeInterval = 0.5, decision: TimeInterval = 1,
                     file: StaticString = #filePath, line: UInt = #line) throws -> (ApprovalOutcome, TimeInterval, ApprovalRequest?) {
        let server = try FakeServer(steps: steps)
        let t0 = Date()
        let outcome = ApprovalClient.run(socketPath: server.path, request: req(), ackTimeout: ack, decisionTimeout: decision)
        let elapsed = Date().timeIntervalSince(t0)
        server.finish()
        return (outcome, elapsed, server.received)
    }

    private let ack = FakeServer.Step.write("{\"ack\":true}\n")

    func testNoSocketReturnsNoDecisionFast() {
        let t0 = Date()
        XCTAssertEqual(ApprovalClient.run(socketPath: tempPath(), request: req()), .noDecision)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05)
    }

    func testStaleSocketFileReturnsNoDecisionFast() throws {
        let path = tempPath()
        let fd = try UnixSocket.listen(path: path)
        UnixSocket.close(fd) // file stays behind, nobody listening
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let t0 = Date()
        XCTAssertEqual(ApprovalClient.run(socketPath: path, request: req()), .noDecision)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05)
    }

    func testServerNeverAcksTimesOut() throws {
        let (outcome, elapsed, _) = try run([.sleep(0.4)], ack: 0.2)
        XCTAssertEqual(outcome, .noDecision)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 0.6)
    }

    func testPassReturnsNoDecision() throws {
        let (outcome, _, _) = try run([.write("{\"pass\":true}\n")])
        XCTAssertEqual(outcome, .noDecision)
    }

    func testAckThenAllow() throws {
        let (outcome, _, received) = try run([ack, .write("{\"decision\":\"allow\"}\n")])
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(received, req())
    }

    func testAckThenDeny() throws {
        let (outcome, _, _) = try run([ack, .write("{\"decision\":\"deny\"}\n")])
        XCTAssertEqual(outcome, .deny)
    }

    func testDecisionWithoutAckIsNoDecision() throws {
        let (outcome, _, _) = try run([.write("{\"decision\":\"allow\"}\n")])
        XCTAssertEqual(outcome, .noDecision)
    }

    func testAckThenPassIsNoDecision() throws {
        let (outcome, _, _) = try run([ack, .write("{\"pass\":true}\n")])
        XCTAssertEqual(outcome, .noDecision)
    }

    func testAckThenCloseIsNoDecision() throws {
        let (outcome, _, _) = try run([ack, .close])
        XCTAssertEqual(outcome, .noDecision)
    }

    func testAckThenSilenceHitsDecisionTimeout() throws {
        let (outcome, elapsed, _) = try run([ack, .sleep(0.5)], decision: 0.3)
        XCTAssertEqual(outcome, .noDecision)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 0.7)
    }

    func testCoalescedRepliesInOneWrite() throws {
        let (outcome, _, _) = try run([.write("{\"ack\":true}\n{\"decision\":\"allow\"}\n")])
        XCTAssertEqual(outcome, .allow)
    }

    func testReplySplitAcrossWrites() throws {
        let (outcome, _, _) = try run([.write("{\"ack\":tr"), .sleep(0.05), .write("ue}\n{\"decision\":"),
                                       .sleep(0.05), .write("\"deny\"}\n")])
        XCTAssertEqual(outcome, .deny)
    }

    func testListenReplacesStaleFileAndSetsDirMode() throws {
        let dir = "/tmp/cw-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/a.sock"
        UnixSocket.close(try UnixSocket.listen(path: path)) // leaves a stale file
        let fd = try UnixSocket.listen(path: path)          // must replace it
        defer { UnixSocket.close(fd) }
        let mode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        let client = try XCTUnwrap(UnixSocket.connect(path: path))
        UnixSocket.close(client)
    }

    func testLineReaderTimesOutAndHandlesEOF() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let reader = LineReader(fd: fds[0])
        let t0 = Date()
        XCTAssertNil(reader.next(timeout: 0.1))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 0.1)
        XCTAssertTrue(UnixSocket.write(fds[1], Data("a\nb".utf8)))
        XCTAssertEqual(reader.next(timeout: 0.5), Data("a".utf8))
        UnixSocket.close(fds[1])
        XCTAssertNil(reader.next(timeout: 0.5)) // "b" never completed, then EOF
        UnixSocket.close(fds[0])
    }
}
