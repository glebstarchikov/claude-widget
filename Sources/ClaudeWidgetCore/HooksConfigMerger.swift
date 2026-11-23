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

    /// PermissionRequest is the only synchronous entry: the hook blocks on the
    /// widget's answer and prints Claude Code's decision. Everything else is fire-and-forget.
    static func isSynchronousEvent(_ event: String) -> Bool { event == "PermissionRequest" }

    /// Seconds Claude Code gives the synchronous entry: room for the hook's 0.5 s
    /// ack and 30 s decision waits, so it's never killed while Gleb is answering.
    static let synchronousTimeout = 60

    static func ourEntry(matcher: String?, binaryPath: String, event: String) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": "\"\(binaryPath)\" \(event)",
            "timeout": isSynchronousEvent(event) ? synchronousTimeout : 10,
        ]
        if !isSynchronousEvent(event) { hook["async"] = true }
        var entry: [String: Any] = ["hooks": [hook]]
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

    /// All entries present, and the PermissionRequest one able to carry an answer:
    /// synchronous, with a whole-second timeout longer than the app's decision wait
    /// (`approvalDecisionTimeout`, 30 s). That's the floor, not a safe margin: the
    /// hook also spends up to 0.5 s on the ack, plus its own start-up, so 31 s
    /// leaves under half a second (the merger writes 60). A hand-edited 90 or 120
    /// still counts. An async entry, or a missing, too short or non-integer
    /// timeout, reads as not installed, so Install (which replaces the widget's
    /// own entries) shows again.
    public static func isInstalled(settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event, _ in
            (hooks[event] as? [[String: Any]] ?? []).contains { entry in
                guard entryIsOurs(entry) else { return false }
                guard isSynchronousEvent(event) else { return true }
                let ours = (entry["hooks"] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains(markerSubstring) == true
                }
                return ours.contains { $0["async"] as? Bool != true && outlastsTheDecisionWait($0["timeout"]) }
            }
        }
    }

    /// A whole number of seconds longer than the app's decision wait. (A parsed
    /// JSON boolean reads as 0 or 1, so it never passes.)
    static func outlastsTheDecisionWait(_ timeout: Any?) -> Bool {
        guard let seconds = timeout as? Int else { return false }
        return Double(seconds) > WidgetConstants.approvalDecisionTimeout
    }
}
