import Foundation

public enum WidgetConstants {
    public static let walkFrameDuration: TimeInterval = 0.45
    public static let pulsePeriod: TimeInterval = 1.2
    public static let blinkIntervalRange: ClosedRange<TimeInterval> = 4...7
    public static let finishedPeekThreshold: TimeInterval = 60
    public static let finishedPeekAutoHide: TimeInterval = 5
    public static let staleAfter: TimeInterval = 4 * 3600
    public static let gcInterval: TimeInterval = 3600
    public static let approvalAckTimeout: TimeInterval = 0.5
    public static let approvalDecisionTimeout: TimeInterval = 30

    public static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/claude-widget", isDirectory: true)
    }
    public static var limitsCache: URL {
        baseDir.appendingPathComponent("limits.json")
    }
    public static var stateDir: URL {
        baseDir.appendingPathComponent("state", isDirectory: true)
    }
    public static var runDir: URL {
        baseDir.appendingPathComponent("run", isDirectory: true)
    }
    public static var approvalSocket: URL {
        runDir.appendingPathComponent("approve.sock")
    }
    public static var binDir: URL {
        baseDir.appendingPathComponent("bin", isDirectory: true)
    }
    public static var hookBinary: URL {
        binDir.appendingPathComponent("claude-widget-hook")
    }
    public static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
}
