import XCTest
@testable import ClaudeWidgetCore

/// Scripted stand-in for the app: accepts one connection, reads the request line, plays the steps.
/// Listens in a fresh directory of its own, or at `path` (left for the caller to clean up).
final class FakeServer {
    enum Step { case write(String), sleep(TimeInterval), close }

    let path: String
    private let dir: String?
    private let listenFD: Int32
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _received: ApprovalRequest?
    var received: ApprovalRequest? { lock.lock(); defer { lock.unlock() }; return _received }

    init(steps: [Step], readsRequest: Bool = true, path: String? = nil) throws {
        if let path {
            dir = nil
            self.path = path
        } else {
            let dir = "/tmp/cw-\(UUID().uuidString.prefix(8))"
            self.dir = dir
            self.path = dir + "/a.sock"
        }
        precondition(self.path.utf8.count < 104)
        listenFD = try UnixSocket.listen(path: self.path)
        let fd = listenFD
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            guard let conn = UnixSocket.accept(fd) else { return }
            defer { UnixSocket.close(conn) }
            if readsRequest, let line = LineReader(fd: conn).next(timeout: 2) {
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
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
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

    private func run(_ steps: [FakeServer.Step], request: ApprovalRequest? = nil, readsRequest: Bool = true, ack: TimeInterval = 0.5, decision: TimeInterval = 1,
                     file: StaticString = #filePath, line: UInt = #line) throws -> (ApprovalOutcome, TimeInterval, ApprovalRequest?) {
        let server = try FakeServer(steps: steps, readsRequest: readsRequest)
        let t0 = Date()
        let outcome = ApprovalClient.run(socketPath: server.path, request: request ?? req(), ackTimeout: ack, decisionTimeout: decision)
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
        let (outcome, elapsed, _) = try run([.sleep(1.0)], ack: 0.2)
        XCTAssertEqual(outcome, .noDecision)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 0.6)
    }

    func testNonReadingServerWithLargeRequestHonoursAckDeadline() throws {
        var big = req()
        big.toolInput = String(repeating: "a", count: 20_000)
        let (outcome, elapsed, _) = try run([.sleep(1.0)], request: big, readsRequest: false, ack: 0.3)
        XCTAssertEqual(outcome, .noDecision)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 0.6)
    }

    func testAcceptSkipsConnectionThatDiedBeforeAccept() throws {
        let path = tempPath()
        let listener = try UnixSocket.listen(path: path)
        defer { UnixSocket.close(listener); try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let dead = try XCTUnwrap(UnixSocket.connect(path: path))
        XCTAssertTrue(UnixSocket.write(dead, Data("x\n".utf8)))
        UnixSocket.close(dead)
        let live = try XCTUnwrap(UnixSocket.connect(path: path))
        defer { UnixSocket.close(live) }
        let accepted = UnixSocket.accept(listener)
        XCTAssertNotNil(accepted)
        accepted.map(UnixSocket.close)
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
        let (outcome, elapsed, _) = try run([ack, .sleep(1.0)], ack: 0.1, decision: 0.3)
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

    /// A second app instance (a dev build next to the installed one) must not
    /// unlink and rebind a live socket: the first would keep listening on a file
    /// nobody can reach any more.
    func testListenNeverTakesOverALiveSocket() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let first = try UnixSocket.listen(path: path)
        var firstOpen = true
        defer { if firstOpen { UnixSocket.close(first) } }
        let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        do {
            UnixSocket.close(try UnixSocket.listen(path: path))
            XCTFail("a second listen took over a live socket")
        } catch {
            XCTAssertEqual(error as? UnixSocketError, UnixSocketError(operation: "listen", code: EADDRINUSE))
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int, inode,
                       "the live socket file is untouched")
        // The first server is still reachable through the path: a client's connection
        // reaches its listener (polled with a deadline, so a regression fails, not hangs).
        let client = try XCTUnwrap(UnixSocket.connect(path: path))
        defer { UnixSocket.close(client) }
        var pfd = pollfd(fd: first, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pfd, 1, 1000), 1, "the first listener got the connection")
        // Once the first server is gone, its file is stale and the next listen takes over.
        UnixSocket.close(first)
        firstOpen = false
        let second = try UnixSocket.listen(path: path)
        UnixSocket.close(second)
    }

    func testListenReplacesARegularFile() throws {
        let path = tempPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("junk".utf8)))
        let fd = try UnixSocket.listen(path: path)
        defer { UnixSocket.close(fd) }
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
