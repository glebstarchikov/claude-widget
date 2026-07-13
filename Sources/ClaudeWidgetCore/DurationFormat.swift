import Foundation

public enum DurationFormat {
    /// Compact duration like "45s" or "4m 20s". Negative inputs clamp to "0s".
    public static func short(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}
