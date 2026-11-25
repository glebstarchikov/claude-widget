import Foundation

/// Copies the hook binary from the app bundle to where Claude Code runs it.
public enum HookBinaryCopy {
    /// Copies `source` over `destination`. Atomic: the copy goes to a temporary
    /// file beside it and is renamed over the installed one, so a hook Claude
    /// starts meanwhile finds the old binary or the new one, never a missing or
    /// half-copied file.
    ///
    /// The copy loses `com.apple.quarantine`. A downloaded app carries it on every
    /// file in its bundle and `copyItem` keeps it, so outside the bundle the user
    /// approved with Open Anyway, Gatekeeper holds the hook and every Claude Code
    /// hook hangs. Only the fresh copy changes; `source` keeps its attributes.
    public static func install(from source: URL, to destination: URL) throws {
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
