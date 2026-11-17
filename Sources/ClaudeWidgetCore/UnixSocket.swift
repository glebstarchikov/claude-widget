import Foundation

public struct UnixSocketError: Error, Equatable {
    public let operation: String
    public let code: Int32
}

/// Thin blocking wrappers over AF_UNIX stream sockets. Every fd is close-on-exec and
/// SO_NOSIGPIPE, so writing to a closed peer fails with EPIPE instead of killing the process.
public enum UnixSocket {
    /// Upper bound on a blocked write; the peers exchange short lines, so this only trips on a stuck peer.
    static let sendTimeout: TimeInterval = 2

    private static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard configure(fd) else { Darwin.close(fd); return nil }
        return fd
    }

    private static func configure(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { return false }
        var tv = timeval(tv_sec: Int(sendTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return true
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Creates the parent directory (0700, tightened if it already exists), removes a stale
    /// file at `path`, binds and listens. Never takes over a live socket: if a server
    /// answers at `path` (another instance of the app), throws EADDRINUSE and leaves it
    /// alone, so the caller can back off and try again once that server is gone.
    public static func listen(path: String) throws -> Int32 {
        guard var addr = address(path) else { throw UnixSocketError(operation: "path", code: ENAMETOOLONG) }
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard chmod(dir, 0o700) == 0 else { throw UnixSocketError(operation: "chmod", code: errno) }
        }
        switch probe(addr) {
        case .live: throw UnixSocketError(operation: "listen", code: EADDRINUSE)
        case .unknown(let code): throw UnixSocketError(operation: "probe", code: code)
        case .dead: unlink(path)
        }
        guard let fd = makeSocket() else { throw UnixSocketError(operation: "socket", code: errno) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno; Darwin.close(fd); throw UnixSocketError(operation: "bind", code: code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno; Darwin.close(fd); throw UnixSocketError(operation: "listen", code: code)
        }
        return fd
    }

    private enum Probe { case live, dead, unknown(Int32) }

    /// Whether a server is listening at `addr`, by connecting without blocking. Refused
    /// (a stale file, or not a socket) or missing is dead; connected, or a full
    /// backlog (EAGAIN), is live; anything else is unknown, so nothing is removed.
    private static func probe(_ addr: sockaddr_un) -> Probe {
        guard let fd = makeSocket() else { return .unknown(errno) }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return .unknown(errno) }
        var addr = addr
        var result: Int32
        repeat {
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } while result != 0 && errno == EINTR
        if result == 0 { return .live }
        switch errno {
        case ECONNREFUSED, ENOENT, ENOTSOCK: return .dead
        case EAGAIN, EINPROGRESS: return .live
        case let code: return .unknown(code)
        }
    }

    /// Blocks for the next usable connection. A connection that died before we got to it (peer
    /// already closed, so sockopts fail) or was aborted (ECONNABORTED) is dropped and the wait
    /// continues; EINTR is retried. Returns nil only when the listener itself is unusable
    /// (closed, invalid, out of descriptors).
    public static func accept(_ fd: Int32) -> Int32? {
        while true {
            let conn = Darwin.accept(fd, nil, nil)
            if conn >= 0 {
                if configure(conn) { return conn }
                Darwin.close(conn)
                continue
            }
            if errno != EINTR && errno != ECONNABORTED { return nil }
        }
    }

    /// Connects without ever blocking: a missing file, a stale file and a full backlog all fail at once.
    public static func connect(path: String) -> Int32? {
        guard var addr = address(path), let fd = makeSocket() else { return nil }
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { Darwin.close(fd); return nil }
        var result: Int32
        repeat {
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } while result != 0 && errno == EINTR
        guard result == 0, fcntl(fd, F_SETFL, flags) != -1 else { Darwin.close(fd); return nil }
        return fd
    }

    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Writes all of `data`; false on any failure (including EPIPE and send timeout).
    public static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    /// Like `write(_:_:)` but gives up when `timeout` elapses (poll for POLLOUT, non-blocking
    /// write), so a peer that never reads cannot stall the caller past its deadline.
    public static func write(_ fd: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        // MSG_DONTWAIT is not honoured for AF_UNIX on Darwin (measured), so use O_NONBLOCK for the duration.
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return false }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < buffer.count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max))))
                if ready < 0 { if errno == EINTR { continue }; return false }
                if ready == 0 { continue }
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { return false }
            }
            return true
        }
    }

    public static func close(_ fd: Int32) {
        Darwin.close(fd)
    }
}

/// Buffered newline-delimited reader with a per-line deadline. Not thread-safe.
public final class LineReader {
    static let maxLineBytes = 1 << 20

    private let fd: Int32
    private var buffer = Data()

    public init(fd: Int32) { self.fd = fd }

    /// One line without its "\n", or nil on timeout, EOF, error or an over-long line.
    /// Lines already buffered (e.g. coalesced replies) are returned without touching the socket.
    public func next(timeout: TimeInterval) -> Data? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            if buffer.count > Self.maxLineBytes { return nil }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remainingMs = Int32(min(Int64((deadline - now + 999_999) / 1_000_000), Int64(Int32.max)))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMs)
            if ready < 0 { if errno == EINTR { continue }; return nil }
            if ready == 0 { continue } // loop re-checks the deadline

            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
            else if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            else { return nil } // EOF or error
        }
    }
}
