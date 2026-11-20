import SwiftUI
import AppKit
import ClaudeWidgetCore

/// The hub's Agents module: one row per session, subagents and pending
/// permission requests nested below. Rows beyond the list cap scroll; the
/// scroll offset survives closing the hub.
struct AgentsModule: View {
    let sessions: [Session]
    let pending: [PendingApproval]
    let answer: (_ id: String, _ allow: Bool) -> Void
    let rowTop: (_ id: String, _ top: Double) -> Void
    /// A pending request to open scrolled to, its bottom edge in view (the pill's
    /// Review), instead of the remembered offset.
    let reveal: String?
    @Binding var scrollOffset: CGFloat
    /// The list's visible height, for requests checking they're wholly on screen.
    @State private var viewportHeight: CGFloat?

    /// Sessions with a pending request but no row yet (the monitor hasn't loaded
    /// their state file), in request order, so every held request is on screen.
    private var unlistedSessions: [String] {
        var ids: [String] = []
        for p in pending where !ids.contains(p.request.sessionId)
            && !sessions.contains(where: { $0.sessionId == p.request.sessionId }) {
            ids.append(p.request.sessionId)
        }
        return ids
    }

    var body: some View {
        if sessions.isEmpty && pending.isEmpty {
            HStack(spacing: 8) {
                GlassCritter(state: .asleep)
                Text("No sessions. The critter sleeps.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SessionRow.horizontalPadding)
            .padding(.vertical, SessionRow.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CappedHeight(maxHeight: HubLayout.maxListHeight) {
                ViewThatFits(in: .vertical) {
                    rows
                    RememberedScroll(offset: $scrollOffset, reveal: reveal) { rows }
                }
            }
            // This frame is the visible list either way: all the rows, or the
            // scroll view's viewport (its content scrolls and clips inside it).
            .coordinateSpace(.named(ListViewport.space))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .environment(\.listViewportHeight, viewportHeight)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(unlistedSessions, id: \.self) { sessionId in
                UnlistedRequestsRow(pending: pending.filter { $0.request.sessionId == sessionId },
                                    answer: answer, rowTop: rowTop)
                    .id(sessionId)
            }
            ForEach(sessions, id: \.sessionId) { session in
                SessionRow(session: session,
                           pending: pending.filter { $0.request.sessionId == session.sessionId },
                           answer: answer, rowTop: rowTop)
                    .id(session.sessionId)
            }
        }
        .scrollTargetLayout()
    }
}

/// Pending requests of a session that has no row yet: the project (from the
/// request) and each request with its buttons.
private struct UnlistedRequestsRow: View {
    let pending: [PendingApproval]
    let answer: (_ id: String, _ allow: Bool) -> Void
    let rowTop: (_ id: String, _ top: Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                GlassCritter(state: .needsYou)
                Text(verbatim: pending.first?.projectName ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            ForEach(pending) { approval in
                PendingRequestView(approval: approval, agentType: nil, answer: answer, rowTop: rowTop)
                    .padding(.leading, 26)   // under the project name
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, SessionRow.horizontalPadding)
        .padding(.vertical, SessionRow.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Offers its content at most `maxHeight` and takes the content's own size.
/// (`.frame(maxHeight:)` would grow to the max whenever the parent offers more.)
private struct CappedHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = min(proposal.height ?? maxHeight, maxHeight)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A vertical scroll view that starts at `offset` (or with the `reveal` request's
/// bottom edge at the bottom, so all of a request that fits is in view) and keeps
/// `offset` updated, so a re-created hub reopens where it was left.
private struct RememberedScroll<Content: View>: View {
    @Binding var offset: CGFloat
    @State private var position: ScrollPosition
    private let reveal: String?
    private let content: Content

    init(offset: Binding<CGFloat>, reveal: String?, @ViewBuilder content: () -> Content) {
        _offset = offset
        _position = State(initialValue: ScrollPosition(y: offset.wrappedValue))
        self.reveal = reveal
        self.content = content()
    }

    var body: some View {
        // The request isn't a scroll target itself (its session row is), so
        // ScrollPosition(id:) can't find it; ScrollViewReader finds any `.id` inside.
        ScrollViewReader { proxy in
            ScrollView { content }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                    offset = y
                }
                .onAppear {
                    if let reveal { proxy.scrollTo(reveal, anchor: .bottom) }
                }
        }
    }
}

struct SessionRow: View {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7

    let session: Session
    /// This session's live permission requests, oldest first.
    let pending: [PendingApproval]
    let answer: (_ id: String, _ allow: Bool) -> Void
    let rowTop: (_ id: String, _ top: Double) -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var statusWord: String {
        switch session.state {
        case .working: return "working"
        case .needsYou: return "needs you"
        case .waiting: return "waiting for you"
        case .ready: return "ready"
        }
    }

    private var detail: String {
        if session.state == .needsYou, let m = session.message { return "needs you · \(m)" }
        if let tool = session.tool { return "\(statusWord) · \(tool)" }
        return statusWord
    }

    private var detailColor: Color {
        session.state == .needsYou ? Color(nsColor: Theme.claudeOrange) : .secondary
    }

    private var workingColor: Color {
        Color(nsColor: Theme.critterColor(state: .working, darkAppearance: colorScheme == .dark).color)
    }

    private func elapsed(_ now: Double) -> String {
        let minutes = Int(max(0, now - session.updatedAt)) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func formatTokens(_ n: Int) -> String {
        n >= 1000 ? "\((n + 500) / 1000)k" : "\(n)"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    GlassCritter(state: session.state.critterState)
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let model = session.model {
                        Text(model)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let bundleId = session.ownerBundleId, let owner = OwnerApp.lookup(bundleId) {
                        Image(nsImage: owner.icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                            .help(owner.name)
                            .accessibilityLabel(owner.name)
                    }
                    Spacer(minLength: 12)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                    if let ctx = session.contextTokens {
                        Text("\(Self.formatTokens(ctx)) ctx")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Text(elapsed(context.date.timeIntervalSince1970))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }

                ForEach(pending) { approval in
                    PendingRequestView(
                        approval: approval,
                        agentType: approval.request.agentId.flatMap { id in
                            session.subagents.first { $0.agentId == id }?.agentType
                        },
                        answer: answer, rowTop: rowTop)
                        .padding(.leading, 26)   // under the project name
                        .padding(.vertical, 2)
                }

                ForEach(session.subagents, id: \.agentId) { sub in
                    HStack(spacing: 6) {
                        Text("└").foregroundStyle(.tertiary)
                        Circle().fill(workingColor).frame(width: 5, height: 5)
                        Text(sub.agentType).foregroundStyle(.secondary)
                        if let tool = sub.tool {
                            Text("· \(tool)").foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.leading, 26)   // under the project name (critter 18 + spacing 8)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background {
                if hovering {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quinary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let bundleId = session.ownerBundleId { activateOwnerApp(bundleId) }
            }
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Icon and name of the app that owns a session, looked up once per bundle id.
@MainActor
private enum OwnerApp {
    private static var cache: [String: (icon: NSImage, name: String)?] = [:]

    static func lookup(_ bundleId: String) -> (icon: NSImage, name: String)? {
        if let hit = cache[bundleId] { return hit }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map {
            (icon: NSWorkspace.shared.icon(forFile: $0.path), name: $0.deletingPathExtension().lastPathComponent)
        }
        cache[bundleId] = found
        return found
    }
}

/// Bring the app that launched a session (its owner) to the front. Goes
/// through LaunchServices even when the app is running: the hub never becomes
/// active, and macOS may refuse `NSRunningApplication.activate()` from an
/// inactive app, while opening the app activates the existing instance.
@MainActor
func activateOwnerApp(_ bundleId: String) {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}
