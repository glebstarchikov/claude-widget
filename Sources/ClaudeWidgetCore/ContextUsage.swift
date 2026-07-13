import Foundation

public enum ContextUsage {
    /// The current context-window size in tokens for the main session: the last
    /// non-sidechain assistant turn's total input (input + cache-creation +
    /// cache-read). Subagent turns (`isSidechain`) are skipped — they have their
    /// own context. Returns nil if no usable assistant record is found.
    public static func tokens(fromTranscriptLines lines: [String]) -> Int? {
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  !((obj["isSidechain"] as? Bool) ?? false),
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let total = input + cacheCreation + cacheRead
            return total > 0 ? total : nil
        }
        return nil
    }
}
