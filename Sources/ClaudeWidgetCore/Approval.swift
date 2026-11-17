import Foundation

/// A permission request the hook forwards to the app over the approval socket.
public struct ApprovalRequest: Codable, Equatable, Sendable {
    public static let maxToolInputBytes = 8192

    public var v: Int = 1
    public var id: String
    public var sessionId: String
    public var agentId: String?
    public var cwd: String
    public var toolName: String
    public var toolDisplay: String?
    public var toolInput: String?
    public var toolInputTruncated: Bool
    public var ownerBundleId: String?

    enum CodingKeys: String, CodingKey {
        case v, id, cwd
        case sessionId = "session_id"
        case agentId = "agent_id"
        case toolName = "tool_name"
        case toolDisplay = "tool_display"
        case toolInput = "tool_input"
        case toolInputTruncated = "tool_input_truncated"
        case ownerBundleId = "owner_bundle_id"
    }
}

extension ApprovalRequest {
    /// Builds a request from a hook payload, capping `toolInput` at 8192 bytes
    /// without splitting a UTF-8 sequence.
    public init(payload: HookPayload, ownerBundleId: String?, id: String) {
        var input = payload.toolInputJSON
        var truncated = false
        if let full = input, full.utf8.count > Self.maxToolInputBytes {
            var bytes = Data(full.utf8.prefix(Self.maxToolInputBytes))
            while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            input = String(data: bytes, encoding: .utf8)
            truncated = true
        }
        self.init(id: id, sessionId: payload.sessionId, agentId: payload.agentId, cwd: payload.cwd,
                  toolName: payload.toolName ?? "", toolDisplay: payload.toolDisplay,
                  toolInput: input, toolInputTruncated: truncated, ownerBundleId: ownerBundleId)
    }
}

public enum ApprovalReply: Equatable, Sendable {
    case ack, pass, allow, deny
}

/// One JSON object per line, newline-terminated.
public enum ApprovalWire {
    public static func encode(_ request: ApprovalRequest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(request)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func decodeRequest(_ data: Data) -> ApprovalRequest? {
        try? JSONDecoder().decode(ApprovalRequest.self, from: data)
    }

    public static func encode(_ reply: ApprovalReply) -> Data {
        let body: String
        switch reply {
        case .ack: body = #"{"ack":true}"#
        case .pass: body = #"{"pass":true}"#
        case .allow: body = #"{"decision":"allow"}"#
        case .deny: body = #"{"decision":"deny"}"#
        }
        return Data((body + "\n").utf8)
    }

    public static func decodeReply(_ data: Data) -> ApprovalReply? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if obj["ack"] as? Bool == true { return .ack }
        if obj["pass"] as? Bool == true { return .pass }
        switch obj["decision"] as? String {
        case "allow": return .allow
        case "deny": return .deny
        default: return nil
        }
    }
}

/// What the hook prints to stdout for Claude Code to parse. Byte-exact.
public enum HookDecision {
    public static let allowJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
    public static let denyJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the notch"}}}"#
}

public enum ApprovalPresentation: Equatable, Sendable {
    case allowable(summary: String, fitsOneLine: Bool)
    case openOnly(summary: String)
}

public enum ApprovalPolicy {
    static let maxBashChars = 400
    static let oneLineChars = 60
    static let maxMCPArgLines = 3
    static let maxMCPValueChars = 80

    /// Tools whose prompts are questions or plans, not permission: the hook never forwards them.
    public static func hookSkips(toolName: String) -> Bool {
        toolName == "AskUserQuestion" || toolName == "ExitPlanMode"
    }

    /// Allow is offered only when the person can see the whole request: truncated
    /// input, unparseable input, and anything long or complex is open-in-app only.
    public static func presentation(for request: ApprovalRequest) -> ApprovalPresentation {
        let name = request.toolName
        let openOnly = ApprovalPresentation.openOnly(summary: request.toolDisplay ?? name)
        guard !request.toolInputTruncated,
              let json = request.toolInput,
              let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return openOnly }

        func single(_ text: String?, limit: Int = .max) -> ApprovalPresentation {
            guard let text, !text.isEmpty, text.count <= limit else { return openOnly }
            return .allowable(summary: text, fitsOneLine: !text.contains("\n") && text.count <= oneLineChars)
        }

        switch name {
        case "Bash": return single(input["command"] as? String, limit: maxBashChars)
        case "WebFetch": return single(input["url"] as? String)
        case "WebSearch": return single(input["query"] as? String)
        default: break
        }
        if name.hasPrefix("mcp__") {
            let lines = input.keys.sorted().map { key -> String in
                let value: String
                if let s = input[key] as? String { value = s } else {
                    let data = (try? JSONSerialization.data(withJSONObject: input[key] ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
                    value = String(data: data, encoding: .utf8) ?? ""
                }
                let shown = value.count > maxMCPValueChars ? String(value.prefix(maxMCPValueChars)) + "…" : value
                return "\(key): \(shown)"
            }
            guard lines.count <= maxMCPArgLines else { return openOnly }
            let summary = ([name] + lines).joined(separator: "\n")
            return .allowable(summary: summary, fitsOneLine: lines.isEmpty)
        }
        return openOnly
    }
}
