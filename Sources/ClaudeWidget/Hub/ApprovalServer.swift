import Foundation
import os
import ClaudeWidgetCore

extension Logger {
    /// Approval logging: fixed text, tool names and outcomes only, never a command or argument.
    static let approval = Logger(subsystem: "com.glebstarchikov.claude-widget", category: "approval")
}

/// The app's end of the approval socket (spec §8). A background thread accepts
/// hook connections; each connection gets its own thread, which reads the one
/// request line, hands it to the main thread, then waits for the hook to hang up.
///
/// Replies are written on the connection's serial queue, which also owns closing
/// the descriptor: once a connection has closed, a reply is dropped, never sent
/// late (and never written to a reused descriptor number).
final class ApprovalServer: @unchecked Sendable {
    typealias Reply = @Sendable (ApprovalReply) -> Void
    /// Called on the main thread with each request and the function that answers
    /// it. Returns what to run (on the main thread) once the hook's connection closes.
    typealias RequestHandler = @MainActor (ApprovalRequest, _ reply: @escaping Reply) -> (@MainActor () -> Void)

    /// The hook sends its request right after connecting.
    private static let requestTimeout: TimeInterval = 2
    private static let maxBackoff: TimeInterval = 30

    private let path: String
    private let lock = NSLock()
    // Guarded by `lock`:
    private var stopped = false
    private var listener: Int32 = -1
    /// The socket file this server bound, so `stop()` never unlinks a newer instance's socket.
    private var boundFile: (dev: dev_t, ino: ino_t)?
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// Ends a backoff sleep early when the server stops.
    private let wake = DispatchSemaphore(value: 0)

    init(path: String) { self.path = path }

    func start(onRequest: @escaping RequestHandler) {
        let thread = Thread { [self] in acceptLoop(onRequest) }
        thread.name = "claude-widget.approval.accept"
        thread.start()
    }

    /// Unlinks the socket file and hangs up every open connection (the hooks then
    /// fall through to Claude Code's own prompt).
    func stop() {
        let (fd, open) = locked { () -> (Int32, [Connection]) in
            stopped = true
            if let bound = boundFile, let current = Self.fileID(path), current == bound { unlink(path) }
            boundFile = nil
            let fd = listener
            listener = -1
            return (fd, Array(connections.values))
        }
        open.forEach { $0.hangUp() }
        if fd >= 0 { UnixSocket.close(fd) }   // wakes a blocked accept, which then sees `stopped`
        wake.signal()
    }

    // MARK: - Accept loop (background thread)

    /// Never ends on its own: if the listener breaks (accept fails, e.g. out of
    /// descriptors) or can't be created, it logs, backs off 1 s doubling to 30 s,
    /// and creates a new one.
    private func acceptLoop(_ onRequest: @escaping RequestHandler) {
        var backoff: TimeInterval = 1
        while true {
            guard let fd = currentListener() else {
                if isStopped { return }
                Logger.approval.error("listen failed; retrying in \(Int(backoff), privacy: .public) s")
                if sleepUnlessStopped(backoff) { return }
                backoff = min(backoff * 2, Self.maxBackoff)
                continue
            }
            guard let conn = UnixSocket.accept(fd) else {
                let code = errno
                if isStopped { return }
                Logger.approval.error("accept failed (errno \(code, privacy: .public)); new listener in \(Int(backoff), privacy: .public) s")
                dropListener(fd)
                if sleepUnlessStopped(backoff) { return }
                backoff = min(backoff * 2, Self.maxBackoff)
                continue
            }
            backoff = 1
            serve(conn, onRequest)
        }
    }

    /// The listening socket, created (and the socket file bound) if there is none.
    private func currentListener() -> Int32? {
        locked {
            if stopped { return nil }
            if listener >= 0 { return listener }
            guard let fd = try? UnixSocket.listen(path: path) else { return nil }
            listener = fd
            boundFile = Self.fileID(path)
            Logger.approval.notice("listening")
            return fd
        }
    }

    private func dropListener(_ fd: Int32) {
        locked {
            guard listener == fd else { return }
            listener = -1
            UnixSocket.close(fd)
        }
    }

    // MARK: - Connections (one thread each)

    private func serve(_ fd: Int32, _ onRequest: @escaping RequestHandler) {
        // The directory is 0700 and the socket 0600; this is the belt to those braces.
        guard UnixSocket.peerUID(fd) == getuid() else { UnixSocket.close(fd); return }
        let conn = Connection(fd: fd)
        let accepted = locked { () -> Bool in
            guard !stopped else { return false }
            connections[ObjectIdentifier(conn)] = conn
            return true
        }
        guard accepted else { conn.close(); return }

        let thread = Thread { [self] in
            defer {
                conn.close()
                locked { _ = connections.removeValue(forKey: ObjectIdentifier(conn)) }
            }
            guard let line = LineReader(fd: fd).next(timeout: Self.requestTimeout) else { return }
            guard let request = ApprovalWire.decodeRequest(line) else {
                conn.send(.pass)
                return
            }
            // Touched only on the main thread: the request is handed over before
            // the close is, and the main queue runs them in that order.
            let onClose = ClosureBox()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onClose.run = onRequest(request, { conn.send($0) }) }
            }
            conn.waitForHangUp()
            conn.close()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onClose.run?() }
            }
        }
        thread.name = "claude-widget.approval.connection"
        thread.start()
    }

    // MARK: - Helpers

    private var isStopped: Bool { locked { stopped } }

    /// Sleeps `seconds`; true if the server stopped meanwhile.
    private func sleepUnlessStopped(_ seconds: TimeInterval) -> Bool {
        _ = wake.wait(timeout: .now() + seconds)
        return isStopped
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func fileID(_ path: String) -> (dev: dev_t, ino: ino_t)? {
        var info = stat()
        return stat(path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
    }
}

private final class ClosureBox: @unchecked Sendable {
    var run: (@MainActor () -> Void)?
}

/// One hook connection.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "claude-widget.approval.reply")
    // Touched only on `queue`:
    private var open = true
    private var answered = false

    init(fd: Int32) { self.fd = fd }

    /// Sends one reply line. Anything but an ack is final: it's followed by a
    /// hang-up, and later replies are dropped. Nothing is sent after the close.
    func send(_ reply: ApprovalReply) {
        queue.async { [self] in
            guard open, !answered else { return }
            // Two short lines per connection never fill the socket buffer; the
            // descriptor's send timeout bounds a stuck peer anyway.
            _ = UnixSocket.write(fd, ApprovalWire.encode(reply))
            if reply != .ack {
                answered = true
                shutdown(fd, SHUT_RDWR)   // the hook still reads the line written before this
            }
        }
    }

    /// Ends the connection without an answer (the hook sees EOF and falls through).
    func hangUp() {
        queue.async { [self] in if open { shutdown(fd, SHUT_RDWR) } }
    }

    /// Blocks until the hook closes its end, or until this side hangs up.
    /// The hook sends nothing after its request; anything it does send is dropped.
    func waitForHangUp() {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            pfd.revents = 0
            if poll(&pfd, 1, -1) < 0 {
                if errno == EINTR { continue }
                return
            }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { continue }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            return   // EOF or error
        }
    }

    func close() {
        queue.sync {
            guard open else { return }
            open = false
            UnixSocket.close(fd)
        }
    }
}
