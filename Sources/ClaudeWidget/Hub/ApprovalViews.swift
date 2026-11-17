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

/// Deny, plus Allow, Review or Open (spec §8), as `ApprovalPolicy.action` decides:
/// Allow only for a request the notch shows in full and in exact columns; Review
/// (opens the hub at the row) in the pill when only the row can show it all; Open
/// (brings the session's app forward) for everything else.
struct ApprovalButtons: View {
    let approval: PendingApproval
    let inPill: Bool
    /// The request's text is laid out legibly (`ApprovalLayout.canOfferAllow`).
    let laidOut: Bool
    let answer: (_ id: String, _ allow: Bool) -> Void
    var review: (_ sessionId: String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    private var indigo: Color {
        Color(nsColor: colorScheme == .dark ? Theme.accentDark : Theme.accentLight)
    }

    /// Never Allow beside text that couldn't be laid out (not measured yet, or too narrow).
    private var action: ApprovalAction {
        let action = ApprovalPolicy.action(for: approval.presentation, on: inPill ? .pill : .row)
        return action == .allow && !laidOut ? .open : action
    }

    var body: some View {
        HStack(spacing: 6) {
            Button("Deny") { answer(approval.id, false) }
                .buttonStyle(.glass)
            switch action {
            case .allow:
                // Not .glassProminent: in this never-key panel its tint never shows
                // and Allow looked exactly like Deny (measured); bordered keeps the indigo.
                Button("Allow") { answer(approval.id, true) }
                    .buttonStyle(.borderedProminent)
                    .tint(indigo)
            case .review:
                Button("Review") { review(approval.request.sessionId) }
                    .buttonStyle(.glass)
            case .open:
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

/// A request's content, whole, never truncated. Wherever Allow may be offered it
/// is laid out in exact columns (`ColumnText`), never word-wrapped. MCP arguments
/// show each key in its own style and column, with the value in the next column
/// (a hanging indent), so a value's continuation rows can't pass for another `key:` line.
struct ApprovalSummary: View {
    let approval: PendingApproval

    var body: some View {
        let summary = approval.presentation.summary
        if ApprovalPolicy.action(for: approval.presentation, on: .row) == .allow {
            if let mcp = MCPCall(summary: summary, request: approval.request) {
                VStack(alignment: .leading, spacing: 2) {
                    // In columns too: it reports a width, so a zero-argument tool keeps its Allow.
                    ColumnText(text: mcp.name)
                    ForEach(mcp.arguments.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            KeyText(key: mcp.arguments[i].key)
                            ColumnText(text: mcp.arguments[i].value)
                        }
                        .padding(.leading, 12)
                    }
                }
            } else {
                ColumnText(text: summary)
            }
        } else {
            // No Allow anywhere for this request, so plain word wrap is fine here.
            Text(verbatim: summary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An MCP argument's key: its own width up to `maxWidth`, wrapping inside that
/// column beyond it, so the value beside it always keeps the rest of the row.
private struct KeyText: View {
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let maxWidth: CGFloat = 160

    let key: String

    var body: some View {
        let label = key + ":"
        let natural = (label as NSString).size(withAttributes: [.font: Self.font]).width.rounded(.up) + 1
        Text(verbatim: label)
            .font(Font(Self.font as CTFont))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: min(natural, Self.maxWidth), alignment: .leading)
    }
}

/// The fewest columns any `ColumnText` in a request was laid out in; negative
/// until measured, nil if there's none.
struct LaidOutColumnsKey: PreferenceKey {
    static let defaultValue: Int? = nil
    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        guard let next = nextValue() else { return }
        value = min(value ?? next, next)
    }
}

/// Monospaced text in fixed columns (`ApprovalLayout`): one row per piece, never
/// word-wrapped or truncated. A row cut from a longer line has a dim ↪ in the
/// gutter (a row after a real line break doesn't), and a space at either end of
/// a row is drawn as a dim ␣, so breaks and spaces read exactly as they'll run.
struct ColumnText: View {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    private static let gutter: CGFloat = 14

    let text: String
    /// Measured; nothing is drawn until it's known.
    @State private var width: CGFloat = 0

    /// Whole characters that fit beside the gutter (1 pt spare against rounding).
    private var columns: Int { Int(((width - Self.gutter - 1) / Self.advance).rounded(.down)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if columns > 0 {
                let pieces = ApprovalLayout.pieces(text, columns: columns)
                ForEach(pieces.indices, id: \.self) { i in row(pieces[i]) }
            }
        }
        .font(Font(Self.font as CTFont))
        // minWidth 0: never sized by its own content, so the measured width converges in one pass.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .preference(key: LaidOutColumnsKey.self, value: columns)
    }

    private func row(_ piece: ApprovalLayout.Piece) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: piece.continuation ? "↪" : " ")
                .foregroundStyle(.tertiary)
                .frame(width: Self.gutter, alignment: .leading)
            if piece.leadingSpace { spaceMark }
            Text(verbatim: piece.middle).fixedSize()
            if piece.trailingSpace { spaceMark }
        }
    }

    private var spaceMark: some View {
        Text(verbatim: "␣").foregroundStyle(.tertiary).frame(width: Self.advance)
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
    /// Reports this row's top edge, so a row that moves under the pointer resets Allow's settle time.
    let rowTop: (_ id: String, _ top: Double) -> Void
    /// From the summary's `ColumnText`s (`LaidOutColumnsKey`).
    @State private var columns: Int?

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
            ApprovalButtons(approval: approval, inPill: false,
                            laidOut: ApprovalLayout.canOfferAllow(columns: columns), answer: answer)
        }
        .onPreferenceChange(LaidOutColumnsKey.self) { columns = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
            rowTop(approval.id, Double(top))
        }
    }
}
