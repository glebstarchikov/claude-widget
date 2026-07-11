import Foundation

public struct HookPayload: Sendable {
    public var sessionId: String
    public var cwd: String
    public var message: String?
    public var notificationType: String?
    public var toolName: String?

    public init?(json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = obj["session_id"] as? String, !id.isEmpty else { return nil }
        sessionId = id
        cwd = obj["cwd"] as? String ?? ""
        message = obj["message"] as? String
        notificationType = obj["notification_type"] as? String
        toolName = obj["tool_name"] as? String
    }
}

public enum SessionUpdate: Equatable, Sendable {
    case write(Session)
    case remove(sessionId: String)
    case ignore
}

public enum EventMapper {
    public static func map(event: String, payload: HookPayload, previous: Session?, now: Double) -> SessionUpdate {
        func session(_ state: SessionState, message: String? = nil) -> Session {
            var workingSince = previous?.workingSince
            if state == .working && previous?.state != .working {
                workingSince = now
            }
            return Session(sessionId: payload.sessionId, state: state, cwd: payload.cwd,
                           message: message, workingSince: workingSince, updatedAt: now)
        }
        switch event {
        case "SessionStart":
            return .write(Session(sessionId: payload.sessionId, state: .ready, cwd: payload.cwd,
                                  message: nil, workingSince: nil, updatedAt: now))
        case "UserPromptSubmit", "PreToolUse":
            return .write(session(.working))
        case "PermissionRequest":
            return .write(session(.needsYou, message: payload.toolName))
        case "Notification":
            return .write(session(.needsYou, message: payload.message))
        case "Stop":
            return .write(session(.waiting))
        case "SessionEnd":
            return .remove(sessionId: payload.sessionId)
        default:
            return .ignore
        }
    }
}
