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
