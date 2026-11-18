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
    /// blocks the calling thread; false if the lock is still held elsewhere.
    public func lock(waitingUpTo timeout: TimeInterval, interval: Duration = .milliseconds(100)) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while !tryLock() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }

    public func unlock() {
        guard held else { return }
        flock(fd, LOCK_UN)
        held = false
    }
}
