import Foundation

/// An MCP request's summary split back into its parts for display. ApprovalPolicy
/// writes the tool name, then one "key: value" line per argument in sorted-key
/// order; the keys are read from the request again (not by splitting at ": ",
/// which a key may contain) and matched scalar by scalar.
public struct MCPCall: Equatable, Sendable {
    /// An argument value's JSON type. The summary writes a non-string as JSON, so
    /// the string "true" and the boolean true read the same there: the view marks
    /// every non-string so the two can't be confused next to Allow.
    public enum ValueKind: String, Equatable, Sendable {
        case string, boolean, number, null, array, object
    }

    public struct Argument: Equatable, Sendable {
        public let key: String
        /// Exactly as the summary shows it.
        public let value: String
        public let kind: ValueKind
    }

    public let name: String
    public let arguments: [Argument]

    /// nil unless `request` is an MCP call whose input parses and whose arguments
    /// match `summary` line for line.
    public init?(summary: String, request: ApprovalRequest) {
        guard request.toolName.hasPrefix("mcp__"),
              let json = request.toolInput,
              let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        let lines = summary.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        let keys = input.keys.sorted()
        guard lines.count == keys.count + 1 else { return nil }
        var arguments: [Argument] = []
        for (key, line) in zip(keys, lines.dropFirst()) {
            let prefix = Array((key + ": ").unicodeScalars)
            guard Array(line.prefix(prefix.count)) == prefix, let value = input[key] else { return nil }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: line.dropFirst(prefix.count))
            arguments.append(Argument(key: key, value: String(text), kind: Self.kind(of: value)))
        }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: lines[0])
        self.name = String(name)
        self.arguments = arguments
    }

    /// The JSON type of a value from `JSONSerialization` (booleans arrive as NSNumber).
    static func kind(of value: Any) -> ValueKind {
        switch value {
        case is String: return .string
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? .boolean : .number
        case is NSNull: return .null
        case is [Any]: return .array
        default: return .object
        }
    }
}
