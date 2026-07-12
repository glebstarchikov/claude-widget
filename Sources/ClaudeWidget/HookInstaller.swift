import Foundation
import ClaudeWidgetCore

struct HookInstaller {
    /// The command string written into settings.json. "$HOME" is expanded by
    /// the shell Claude Code uses to run hooks, so the config is portable.
    static let settingsBinaryPath = "$HOME/.claude/claude-widget/bin/claude-widget-hook"

    /// The claude-widget-hook binary ships next to the app executable, both in
    /// `swift build` output and inside Claude Widget.app/Contents/MacOS.
    private var bundledHookBinary: URL {
        Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("claude-widget-hook")
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: WidgetConstants.claudeSettings.path) else { return [:] }
        let data = try Data(contentsOf: WidgetConstants.claudeSettings)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: WidgetConstants.claudeSettings, options: .atomic)
    }

    private func backupSettings() throws {
        guard FileManager.default.fileExists(atPath: WidgetConstants.claudeSettings.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = WidgetConstants.claudeSettings.deletingLastPathComponent()
        // The unix-second stamp collides when two writes land in the same second
        // (e.g. a remove immediately followed by an install). copyItem throws on an
        // existing destination, which would abort the write mid-op — so append a
        // counter to guarantee a fresh backup name rather than losing the backup.
        var backup = dir.appendingPathComponent("settings.json.backup-claude-widget-\(stamp)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = dir.appendingPathComponent("settings.json.backup-claude-widget-\(stamp)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.copyItem(at: WidgetConstants.claudeSettings, to: backup)
        pruneBackups(in: dir, keeping: 5)
    }

    /// Keeps only the newest `keep` widget backups — otherwise they accumulate
    /// one per install/remove forever.
    private func pruneBackups(in dir: URL, keeping keep: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("settings.json.backup-claude-widget-") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        for old in backups.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    func install() throws {
        try FileManager.default.createDirectory(at: WidgetConstants.binDir,
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: WidgetConstants.hookBinary.path) {
            try FileManager.default.removeItem(at: WidgetConstants.hookBinary)
        }
        try FileManager.default.copyItem(at: bundledHookBinary, to: WidgetConstants.hookBinary)

        try backupSettings()
        let merged = HooksConfigMerger.merge(settings: try readSettings(),
                                             binaryPath: Self.settingsBinaryPath)
        try writeSettings(merged)
    }

    func remove() throws {
        try backupSettings()
        let stripped = HooksConfigMerger.remove(settings: try readSettings())
        try writeSettings(stripped)
    }

    /// Copies the bundled hook binary over the installed one without touching
    /// settings.json. Called on every launch so app updates propagate (spec §4.4).
    func refreshBinary() throws {
        try FileManager.default.createDirectory(at: WidgetConstants.binDir,
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: WidgetConstants.hookBinary.path) {
            try FileManager.default.removeItem(at: WidgetConstants.hookBinary)
        }
        try FileManager.default.copyItem(at: bundledHookBinary, to: WidgetConstants.hookBinary)
    }

    /// Installed means: settings entries present AND the binary exists.
    /// A missing binary (spec §8) resurfaces the Install button.
    func isInstalled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return HooksConfigMerger.isInstalled(settings: settings)
            && FileManager.default.fileExists(atPath: WidgetConstants.hookBinary.path)
    }
}
