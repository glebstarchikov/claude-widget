import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public var label: String
    public var percent: Double
    public var resetsAt: Date?
    public var severity: String?
    public var isActive: Bool

    public init(label: String, percent: Double, resetsAt: Date? = nil, severity: String? = nil, isActive: Bool = false) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        self.isActive = isActive
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public var provider: String
    public var windows: [UsageWindow]
    public var fetchedAt: Date

    public init(provider: String, windows: [UsageWindow], fetchedAt: Date) {
        self.provider = provider
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

public enum UsageParseError: Error, Equatable, Sendable {
    case notAnObject
    case noWindows
}

public enum UsageParser {
    public static func parseClaude(_ data: Data, fetchedAt: Date) throws -> ProviderUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageParseError.notAnObject
        }
        var windows: [UsageWindow] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let percent = number(entry["percent"]) else { continue }
                windows.append(UsageWindow(
                    label: label(for: entry),
                    percent: percent,
                    resetsAt: date(entry["resets_at"]),
                    severity: entry["severity"] as? String,
                    isActive: entry["is_active"] as? Bool ?? false))
            }
        }
        if windows.isEmpty {
            for (key, label) in [("five_hour", "5h"), ("seven_day", "week")] {
                guard let w = root[key] as? [String: Any], let percent = number(w["utilization"]) else { continue }
                windows.append(UsageWindow(label: label, percent: percent, resetsAt: date(w["resets_at"])))
            }
        }
        guard !windows.isEmpty else { throw UsageParseError.noWindows }
        return ProviderUsage(provider: "Claude", windows: windows, fetchedAt: fetchedAt)
    }

    private static func label(for entry: [String: Any]) -> String {
        let raw = (entry["group"] as? String) ?? (entry["kind"] as? String) ?? "limit"
        let base: String
        switch raw {
        case "weekly": base = "week"
        case "five_hour", "session": base = "5h"
        default: base = raw
        }
        if let scope = entry["scope"] as? [String: Any],
           let model = scope["model"] as? [String: Any],
           let name = model["display_name"] as? String, !name.isEmpty {
            return "\(name) · \(base)"
        }
        return base
    }

    // JSON booleans bridge to NSNumber; they are not percentages.
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFraction.date(from: s) { return d }
            return ISO8601DateFormatter().date(from: s)
        }
        if let n = number(value) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        return nil
    }
}

public enum UsageRequest {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func make(token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue(TokenRefresh.userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }
}

public enum ResetFormat {
    /// Longer waits read as this many days: an absurd `resets_at` from the feed
    /// (1e300, say) must not trap converting to Int.
    static let maxDays = 999

    public static func resetsIn(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }   // also NaN
        let minutes = Int(min(seconds, Double(maxDays) * 86400) / 60)
        if minutes < 1 { return "<1m" }
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

public enum UsageFetchOutcome: Equatable, Sendable { case success, failure, unauthorized }

public enum UsagePollPolicy {
    public static func nextDelay(after outcome: UsageFetchOutcome, consecutiveFailures: Int) -> TimeInterval {
        switch outcome {
        case .success: return 300
        case .unauthorized: return 1800
        case .failure:
            let exponent = min(max(consecutiveFailures, 1) - 1, 10)
            return min(60 * pow(2, Double(exponent)), 1800)
        }
    }
}
