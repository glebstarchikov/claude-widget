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

/// Where a pending request is shown: the small pill, or its row in the hub.
public enum ApprovalSurface: Sendable {
    case pill, row
}

/// The button next to Deny.
public enum ApprovalAction: Equatable, Sendable {
    /// Answer yes from the notch.
    case allow
    /// Open the hub at the request's row, which offers Allow (pill only).
    case review
    /// Bring the session's app forward and answer there.
    case open
}

public enum ApprovalPolicy {
    static let maxBashChars = 400
    static let oneLineChars = 60
    static let maxMCPArgLines = 3
    static let maxMCPValueChars = 80
    static let maxMCPKeyChars = 32

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
            guard let text, !text.isEmpty, text.unicodeScalars.count <= limit, isPlainText(text) else { return openOnly }
            let oneLine = !text.contains(where: \.isNewline) && !text.contains("\t") && text.count <= oneLineChars
            return .allowable(summary: text, fitsOneLine: oneLine)
        }

        switch name {
        case "Bash":
            // Anything that changes how the command runs must be visible, so only
            // known-harmless keys (and the two flags when false) stay one-click.
            for (key, value) in input {
                switch key {
                case "command", "description", "timeout": continue
                case "dangerouslyDisableSandbox", "run_in_background":
                    if (value as? Bool) == false { continue }
                    return openOnly
                default: return openOnly
                }
            }
            return single(input["command"] as? String, limit: maxBashChars)
        case "WebFetch": return single(input["url"] as? String, limit: maxBashChars)
        case "WebSearch": return single(input["query"] as? String, limit: maxBashChars)
        default: break
        }
        if name.hasPrefix("mcp__") {
            guard isPlainText(name), !name.contains(where: \.isNewline) else { return openOnly }
            var lines: [String] = []
            for key in input.keys.sorted() {
                let value: String
                if let s = input[key] as? String { value = s } else {
                    let data = (try? JSONSerialization.data(withJSONObject: input[key] ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
                    value = String(data: data, encoding: .utf8) ?? ""
                }
                // Keys are short printable ASCII, so a key can never crowd its value off the row.
                guard value.unicodeScalars.count <= maxMCPValueChars, isPlainText(key), isPlainText(value),
                      key.unicodeScalars.count <= maxMCPKeyChars, isPrintableASCII(key),
                      !key.contains(where: \.isNewline), !value.contains(where: \.isNewline) else { return openOnly }
                lines.append("\(key): \(value)")
            }
            guard lines.count <= maxMCPArgLines else { return openOnly }
            return .allowable(summary: ([name] + lines).joined(separator: "\n"), fitsOneLine: lines.isEmpty)
        }
        return openOnly
    }

    /// Allow is offered only where the whole request is visible and laid out
    /// exactly: an `.allowable` request in printable ASCII (one column per
    /// character, so ApprovalLayout's rows are exact), and in the pill only when it
    /// also fits on one line. Otherwise the pill offers Review if the row would
    /// offer Allow, and everything else gets Open.
    public static func action(for presentation: ApprovalPresentation, on surface: ApprovalSurface) -> ApprovalAction {
        guard case .allowable(let summary, let fitsOneLine) = presentation, isPrintableASCII(summary)
        else { return .open }
        return surface == .row || fitsOneLine ? .allow : .review
    }

    /// Space through "~", plus line breaks. No tabs or other control characters.
    public static func isPrintableASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "\n" || (0x20...0x7E).contains($0.value) }
    }

    /// Newline and tab are fine; any other control, format (incl. bidi) or
    /// line/paragraph-separator scalar could make the display differ from what runs.
    static func isPlainText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar.properties.isDefaultIgnorableCodePoint { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }
}
