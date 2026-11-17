import SwiftUI
import ClaudeWidgetCore

/// Sizes shared by the hub's views and its panel (HubController).
enum HubLayout {
    static let width: CGFloat = 660
    static let pillSize = CGSize(width: 380, height: 48)
    /// The pill with a permission request: 60 monospaced characters (~445 pt) fit
    /// on its request line without wrapping.
    static let approvalPillWidth: CGFloat = 540
    static let cornerRadius: CGFloat = 24
    static let moduleSpacing: CGFloat = 10
    static let modulePadding: CGFloat = 12
    static let containerSpacing: CGFloat = 16
    /// Gap between the menu bar (or the critter) and the hub's top edge.
    static let gapBelowMenuBar: CGFloat = 8
    /// Agents list height before it scrolls: about six one-line rows.
    static let maxListHeight: CGFloat = 6 * 36
    /// Limits module content: a ring with its label, or up to three lines of text.
    static let limitsHeight: CGFloat = 54
    /// Transparent room around the content inside the panel, for the glass
    /// shadow and the spring's overshoot.
    static let margin: CGFloat = 24

    static var maxHubHeight: CGFloat { limitsHeight + moduleSpacing + maxListHeight + 4 * modulePadding }
    static var panelSize: CGSize {
        CGSize(width: width + 2 * margin, height: maxHubHeight + 2 * margin)
    }
}

/// The panel's root: the expanded hub, the pill, or nothing. Content hangs
/// from the top-center of the panel, `HubLayout.margin` below its top edge.
struct HubView: View {
    @ObservedObject var model: HubModel
    /// Reports the expanded hub's height so the panel knows where it is.
    let onHubHeightChange: (CGFloat) -> Void
    /// Reports the pill's size (the one with a request is bigger than the plain one).
    let onPillSizeChange: (CGSize) -> Void

    @State private var scrollOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.75)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .scale(scale: 0.4, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.85, anchor: .top).combined(with: .opacity))
    }

    private var pillSession: Session? {
        guard let pill = model.pill else { return nil }
        return model.sessions.first { $0.sessionId == pill.sessionId }
    }

    var body: some View {
        GlassEffectContainer(spacing: HubLayout.containerSpacing) {
            if model.expanded {
                VStack(spacing: HubLayout.moduleSpacing) {
                    if model.limits != .off {
                        LimitsModule(state: model.limits, fromCache: model.limitsFromCache,
                                     saveFailed: model.limitsSaveFailed, openSettings: model.openSettings)
                            .padding(HubLayout.modulePadding)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: HubLayout.cornerRadius,
                                                                        style: .continuous))
                    }
                    AgentsModule(sessions: model.sessions, pending: model.pending,
                                 answer: model.answerApproval, reveal: model.revealSessionId,
                                 scrollOffset: $scrollOffset)
                        .padding(HubLayout.modulePadding)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: HubLayout.cornerRadius,
                                                                    style: .continuous))
                }
                .frame(width: HubLayout.width)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHubHeightChange($0) }
                .transition(transition)
            } else if case .needsYou? = model.pill, let first = model.pending.first {
                ApprovalPillView(approval: first, extra: model.pending.count - 1,
                                 answer: model.answerApproval, review: model.reviewApproval)
                    // A new request gets fresh buttons: a press held across the swap is dropped.
                    .id(first.id)
                    .glassEffect(.regular, in: Capsule())
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { onPillSizeChange($0) }
                    .transition(transition)
            } else if let pill = model.pill, let session = pillSession {
                PillView(pill: pill, session: session)
                    .glassEffect(.regular, in: Capsule())
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { onPillSizeChange($0) }
                    .transition(transition)
            }
        }
        .padding(.top, HubLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: model.expanded)
        .animation(animation, value: model.pill)
        .animation(animation, value: model.pending)
    }
}
