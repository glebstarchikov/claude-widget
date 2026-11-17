import SwiftUI
import ClaudeWidgetCore

/// The small glass capsule under the notch for an alert. Click focuses the
/// session's app; hovering it expands into the full hub (HubController).
struct PillView: View {
    let pill: Pill
    let session: Session

    private var critterState: AggregateState {
        switch pill {
        case .needsYou: return .needsYou
        case .finished: return .waiting
        }
    }

    private var detail: String {
        switch pill {
        case .needsYou: return "· " + (session.message ?? "needs you")
        case .finished(_, let duration): return "finished · \(DurationFormat.short(duration))"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            GlassCritter(state: critterState, size: 22)
            HStack(spacing: 5) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .layoutPriority(1)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: HubLayout.pillSize.width, height: HubLayout.pillSize.height)
        .contentShape(Capsule())
        .onTapGesture {
            if let bundleId = session.ownerBundleId { activateOwnerApp(bundleId) }
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// The needs-you pill while a permission request is live: the oldest request,
/// "+N" for the others, and its buttons. Unlike the plain pill it doesn't grow
/// into the hub on hover (the buttons would move under the pointer); Review
/// opens the hub. Clicking elsewhere on it focuses the session's app.
struct ApprovalPillView: View {
    let approval: PendingApproval
    /// Pending requests after this one.
    let extra: Int
    let answer: (_ id: String, _ allow: Bool) -> Void
    let review: (_ sessionId: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                GlassCritter(state: .needsYou, size: 22)
                HStack(spacing: 5) {
                    Text(verbatim: approval.projectName)
                        .font(.system(size: 13, weight: .semibold))
                    if let tool = approval.toolLabel {
                        Text(verbatim: tool)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if extra > 0 {
                        Text("+\(extra)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                ApprovalButtons(approval: approval, inPill: true, answer: answer, review: review)
            }
            // The request gets the full width under the name: a one-line request
            // (≤ 60 characters) fits without a soft wrap, which could hide whether
            // there's a space at the break.
            Group {
                if approval.presentation.offersAllow(inPill: true) {
                    ApprovalSummary(approval: approval)
                } else {
                    // No Allow in the pill, so a one-line preview is enough;
                    // Review / Open shows the rest.
                    Text(verbatim: approval.presentation.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 32)   // under the project name (critter 22 + spacing 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: HubLayout.approvalPillWidth)
        .frame(minHeight: HubLayout.pillSize.height)
        .contentShape(Capsule())
        .onTapGesture {
            if let owner = approval.request.ownerBundleId { activateOwnerApp(owner) }
        }
    }
}
