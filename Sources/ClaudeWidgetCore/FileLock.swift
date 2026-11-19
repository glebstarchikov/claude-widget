import Foundation

/// An exclusive advisory lock (`flock`) on a file. Every process that opens the
/// same path contends for it, so two copies of the app (installed + a dev build)
/// can take turns. The kernel drops the lock when its holder closes the file or
/// dies, so a crash never leaves it stuck.
public final class FileLock {
    private let fd: Int32
    private var held = false

    /// Opens the lock file at `path`, creating it (0600) and its directory (0700)
    /// if needed. nil if it can't be opened (a symlink is refused).
    public init?(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }   // also releases the lock

    /// Takes the lock if no one else holds it, without waiting.
    public func tryLock() -> Bool {
        if held { return true }
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { held = true; return true }
            if errno != EINTR { return false }
        }
    }

    /// Takes the lock, checking every `interval` until `timeout` passes. Never
    /// blocks the calling thread. False if the lock is still held elsewhere, or if
    /// the task is cancelled or `giveUp` says to stop (both checked before each try).
    public func lock(waitingUpTo timeout: TimeInterval, interval: Duration = .milliseconds(100),
                     giveUpIf giveUp: @Sendable () async -> Bool = { false }) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            if Task.isCancelled { return false }
            if await giveUp() { return false }
            if tryLock() { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: interval)
        }
    }

    /// The lock file's first bytes, as UTF-8. Read only while holding the lock.
    public func contents() -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return "" }
        return String(decoding: buffer[..<count], as: UTF8.self)
    }

    /// When the lock file's contents were last written (its mtime); nil if unknown.
    public func modified() -> Date? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    /// Replaces the lock file's contents. Written only while holding the lock, and
    /// never a secret: other processes of the same user can read it.
    @discardableResult
    public func replaceContents(with text: String) -> Bool {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return written == bytes.count && ftruncate(fd, off_t(bytes.count)) == 0
    }

    public func unlock() {
        guard held else { return }
        flock(fd, LOCK_UN)
        held = false
    }
}
