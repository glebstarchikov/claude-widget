import Foundation

public enum TranscriptModel {
    /// The model of the main session's newest reply, so a resumed session gets its
    /// badge and a `/model` switch shows after the next reply. Subagent turns
    /// (`isSidechain`) and Claude Code's `<synthetic>` placeholder replies are
    /// skipped. Returns nil if no usable reply is found.
    public static func latest(fromTranscriptLines lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  !((obj["isSidechain"] as? Bool) ?? false),
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty, model != "<synthetic>" else { continue }
            return model
        }
        return nil
    }
}
