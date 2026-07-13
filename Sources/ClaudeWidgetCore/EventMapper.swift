import Foundation

public struct HookPayload: Sendable {
    public var sessionId: String
    public var cwd: String
    public var message: String?
    public var toolName: String?
    public var toolDisplay: String?
    public var agentId: String?
    public var agentType: String?
    public var model: String?
    public var sessionTitle: String?
    public var transcriptPath: String?

    public init?(json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = obj["session_id"] as? String, !id.isEmpty else { return nil }
        sessionId = id
        cwd = obj["cwd"] as? String ?? ""
        message = obj["message"] as? String
        toolName = obj["tool_name"] as? String
        agentId = (obj["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        agentType = obj["agent_type"] as? String
        model = obj["model"] as? String
        sessionTitle = obj["session_title"] as? String
        transcriptPath = obj["transcript_path"] as? String
        if let name = toolName {
            toolDisplay = Self.formatTool(name: name, input: obj["tool_input"] as? [String: Any])
        }
    }

    /// A compact "tool: target" label, e.g. "Bash: npm test" or "Edit page.tsx".
    static func formatTool(name: String, input: [String: Any]?) -> String {
        func trunc(_ s: String, _ n: Int) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > n ? String(t.prefix(n)) + "…" : t
        }
        switch name {
        case "Bash":
            if let cmd = input?["command"] as? String { return "Bash: \(trunc(cmd, 42))" }
        case "Edit", "Write", "Read", "NotebookEdit":
            if let path = input?["file_path"] as? String { return "\(name) \((path as NSString).lastPathComponent)" }
        case "Grep", "Glob":
            if let p = input?["pattern"] as? String { return "\(name): \(trunc(p, 30))" }
        default:
            break
        }
        return name
    }
}

public enum SessionUpdate: Equatable, Sendable {
    case write(Session)
    case remove(sessionId: String)
    case ignore
}

public enum SubagentUpdate: Equatable, Sendable {
    case write(SubagentRecord)
    case remove(agentId: String)
    case ignore
}

public enum EventMapper {
    /// Maps a main-loop hook event (no agent_id) to a session state update,
    /// preserving model/title across the session and tracking the current tool.
    public static func map(event: String, payload: HookPayload, previous: Session?, now: Double) -> SessionUpdate {
        func session(_ state: SessionState, message: String? = nil, tool: String?) -> Session {
            var workingSince = previous?.workingSince
            if state == .working && previous?.state != .working { workingSince = now }
            return Session(sessionId: payload.sessionId, state: state, cwd: payload.cwd,
                           message: message, model: previous?.model, title: previous?.title,
                           tool: tool, contextTokens: previous?.contextTokens,
                           workingSince: workingSince, updatedAt: now)
        }
        switch event {
        case "SessionStart":
            // SessionStart re-fires on compaction / resume / clear, and those
            // payloads omit the model (it's sent only on the initial startup).
            // Preserve what we already captured so a later SessionStart can't wipe it.
            return .write(Session(sessionId: payload.sessionId, state: .ready, cwd: payload.cwd,
                                  message: nil,
                                  model: payload.model ?? previous?.model,
                                  title: payload.sessionTitle ?? previous?.title,
                                  tool: nil, contextTokens: previous?.contextTokens,
                                  workingSince: nil, updatedAt: now))
        case "UserPromptSubmit":
            return .write(session(.working, tool: nil))
        case "PreToolUse":
            return .write(session(.working, tool: payload.toolDisplay ?? previous?.tool))
        case "PermissionRequest":
            return .write(session(.needsYou, message: payload.toolName, tool: payload.toolDisplay ?? previous?.tool))
        case "Notification":
            return .write(session(.needsYou, message: payload.message, tool: previous?.tool))
        case "Stop":
            return .write(session(.waiting, tool: nil))
        case "SessionEnd":
            return .remove(sessionId: payload.sessionId)
        default:
            return .ignore
        }
    }

    /// Maps a subagent hook event (has agent_id) to a subagent-record update.
    public static func mapSubagent(event: String, payload: HookPayload,
                                   previous: SubagentRecord?, now: Double) -> SubagentUpdate {
        guard let agentId = payload.agentId else { return .ignore }
        let agentType = payload.agentType ?? previous?.agentType ?? "subagent"
        func record(tool: String?) -> SubagentRecord {
            SubagentRecord(sessionId: payload.sessionId, agentId: agentId,
                           agentType: agentType, tool: tool, updatedAt: now)
        }
        switch event {
        case "SubagentStart":
            return .write(record(tool: nil))
        case "PreToolUse":
            return .write(record(tool: payload.toolDisplay ?? previous?.tool))
        case "SubagentStop":
            return .remove(agentId: agentId)
        default:
            return .ignore
        }
    }
}
