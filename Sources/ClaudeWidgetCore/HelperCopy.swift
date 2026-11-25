import Foundation

/// A bundle file as it was when the app started: a regular file's device, inode,
/// size and modification time. `cp` onto an existing file keeps the inode, so the
/// size and time count too. nil for a missing file or anything but a regular file.
public struct LaunchStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mtime: Int
    let mtimeNanos: Int

    public init?(of url: URL) {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        device = st.st_dev
        inode = st.st_ino
        size = st.st_size
        mtime = st.st_mtimespec.tv_sec
        mtimeNanos = st.st_mtimespec.tv_nsec
    }
}

public enum HelperCopyError: LocalizedError {
    /// The bundle file differs from its `LaunchStamp`, or had none.
    case changedSinceLaunch

    public var errorDescription: String? {
        "Claude Widget changed on disk since it started. Quit it and open it again."
    }
}

/// Copies a helper from the app bundle into `WidgetConstants.binDir`: the hook
/// binary Claude Code runs, and the now-playing adapter perl loads.
public enum HelperCopy {
    /// Copies `source` over `destination`. Atomic: the copy goes to a temporary
    /// file beside it and is renamed over the installed one, so a hook Claude
    /// starts meanwhile finds the old binary or the new one, never a missing or
    /// half-copied file, and a process that has the old one open keeps it.
    ///
    /// The copy loses `com.apple.quarantine`. A downloaded app carries it on every
    /// file in its bundle and `copyItem` keeps it, so outside the bundle the user
    /// approved with Open Anyway, Gatekeeper stops the copy: every Claude Code hook
    /// is killed, and perl is refused the adapter. Only the fresh copy changes;
    /// `source` and every other file keep their attributes.
    ///
    /// Only the file the user approved is copied: `source` must still match
    /// `launchStamp`, taken when the app started. A bundle replaced while the app
    /// runs throws `HelperCopyError.changedSinceLaunch` and keeps its flag.
    public static func install(from source: URL, to destination: URL, launchStamp: LaunchStamp?) throws {
        guard let launchStamp, LaunchStamp(of: source) == launchStamp else {
            throw HelperCopyError.changedSinceLaunch
        }
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var staging = dir.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            var values = URLResourceValues()
            values.quarantineProperties = nil
            try staging.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        guard rename(staging.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
