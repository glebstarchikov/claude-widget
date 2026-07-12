import Foundation

public enum HooksConfigMerger {
    public static let markerSubstring = "claude-widget-hook"

    public static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "*"),
        ("PermissionRequest", "*"),
        ("Notification", nil),
        ("Stop", nil),
        ("SessionEnd", nil),
        ("SubagentStart", nil),
        ("SubagentStop", nil),
    ]

    static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        let commands = (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        return commands.contains { $0.contains(markerSubstring) }
    }

    static func ourEntry(matcher: String?, binaryPath: String, event: String) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "\"\(binaryPath)\" \(event)",
                "async": true,
                "timeout": 10,
            ] as [String: Any]]
        ]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    public static func merge(settings: [String: Any], binaryPath: String) -> [String: Any] {
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, matcher) in events {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !entryIsOurs($0) }
            entries.append(ourEntry(matcher: matcher, binaryPath: binaryPath, event: event))
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    public static func remove(settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return result }
        for (event, _) in events {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryIsOurs($0) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        result["hooks"] = hooks
        return result
    }

    public static func isInstalled(settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event, _ in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: entryIsOurs)
        }
    }
}
