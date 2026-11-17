import SwiftUI
import ClaudeWidgetCore

extension PendingApproval {
    /// "Bash", "WebFetch" or "WebSearch": the tool whose command, URL or query the
    /// summary is. MCP and open-only summaries already start with the tool.
    var toolLabel: String? {
        guard case .allowable = presentation, !request.toolName.hasPrefix("mcp__") else { return nil }
        return request.toolName
    }

    var projectName: String { (request.cwd as NSString).lastPathComponent }
}

/// Deny, plus Allow, Review or Open (spec §8). Allow appears only for a request the
/// notch shows in full: `.allowable`, and in the pill only when it fits on one line;
/// otherwise the pill offers Review (opens the hub at the row). Open-only requests
/// (a diff, an unknown tool) get Open, which brings the session's app forward.
struct ApprovalButtons: View {
    let approval: PendingApproval
    let inPill: Bool
    let answer: (_ id: String, _ allow: Bool) -> Void
    var review: (_ sessionId: String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    private var indigo: Color {
        Color(nsColor: colorScheme == .dark ? Theme.accentDark : Theme.accentLight)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button("Deny") { answer(approval.id, false) }
                .buttonStyle(.glass)
            if approval.presentation.offersAllow(inPill: inPill) {
                // Not .glassProminent: in this never-key panel its tint never shows
                // and Allow looked exactly like Deny (measured); bordered keeps the indigo.
                Button("Allow") { answer(approval.id, true) }
                    .buttonStyle(.borderedProminent)
                    .tint(indigo)
            } else if case .allowable = approval.presentation {
                Button("Review") { review(approval.request.sessionId) }
                    .buttonStyle(.glass)
            } else {
                Button("Open") {
                    if let owner = approval.request.ownerBundleId { activateOwnerApp(owner) }
                }
                .buttonStyle(.glass)
            }
        }
        .controlSize(.small)
        .fixedSize()
        // The hub's panel is never key, which would draw these as inactive (grey).
        .environment(\.appearsActive, true)
    }
}

/// A request's content, whole: wrapped, never truncated. Commands, URLs, queries
/// and argument values are monospaced. MCP arguments show each key in its own
/// style and column, with the value wrapping in the next column (a hanging
/// indent), so a wrapped value can never pass for another `key:` line.
struct ApprovalSummary: View {
    let approval: PendingApproval
    var size: CGFloat = 12

    var body: some View {
        switch approval.presentation {
        case .allowable(let summary, _):
            if let mcp = MCPCall(summary: summary, request: approval.request) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: mcp.name)
                        .font(.system(size: size, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(mcp.arguments.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: mcp.arguments[i].key + ":")
                                .font(.system(size: size, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            wrapped(mcp.arguments[i].value, monospaced: true)
                        }
                        .padding(.leading, 12)
                    }
                }
            } else {
                wrapped(summary, monospaced: true)
            }
        case .openOnly(let summary):
            wrapped(summary, monospaced: false)
        }
    }

    private func wrapped(_ text: String, monospaced: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: size, design: monospaced ? .monospaced : .default))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An MCP summary split back into its parts. ApprovalPolicy writes the tool name,
/// then one "key: value" line per argument in sorted-key order; the keys are read
/// from the request again (not by splitting at ": ", which a key may contain) and
/// matched scalar by scalar.
private struct MCPCall {
    let name: String
    let arguments: [(key: String, value: String)]

    init?(summary: String, request: ApprovalRequest) {
        guard request.toolName.hasPrefix("mcp__"),
              let json = request.toolInput,
              let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        let lines = summary.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        let keys = input.keys.sorted()
        guard lines.count == keys.count + 1 else { return nil }
        var arguments: [(key: String, value: String)] = []
        for (key, line) in zip(keys, lines.dropFirst()) {
            let prefix = Array((key + ": ").unicodeScalars)
            guard Array(line.prefix(prefix.count)) == prefix else { return nil }
            var value = String.UnicodeScalarView()
            value.append(contentsOf: line.dropFirst(prefix.count))
            arguments.append((key, String(value)))
        }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: lines[0])
        self.name = String(name)
        self.arguments = arguments
    }
}

/// A pending request inline in its session's row: the whole request and its buttons.
struct PendingRequestView: View {
    let approval: PendingApproval
    /// The subagent that asked, if one did.
    let agentType: String?
    let answer: (_ id: String, _ allow: Bool) -> Void

    private var label: String? {
        let parts = [agentType, approval.toolLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let label {
                    Text(verbatim: label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: Theme.claudeOrange))
                }
                ApprovalSummary(approval: approval)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ApprovalButtons(approval: approval, inPill: false, answer: answer)
        }
    }
}
