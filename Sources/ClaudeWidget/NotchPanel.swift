import AppKit
import SwiftUI
import ClaudeWidgetCore

/// The notch/peek layout for the built-in display, derived once from the screen
/// so the panel frame (NotchPanelController) and the hover zones
/// (NotchHoverController) can never drift apart. Single source of truth for the
/// peek's dimensions.
struct NotchMetrics {
    static let minNotchWidth: CGFloat = 120
    static let fallbackNotchWidth: CGFloat = 200   // external display / older Mac: no notch reported
    static let minPeekWidth: CGFloat = 340
    static let peekSidePadding: CGFloat = 120      // peek extends this far past the notch
    static let visibleHeight: CGFloat = 58         // peek height below the menu bar
    static let cornerRadius: CGFloat = 20

    let screen: NSScreen
    let topInset: CGFloat
    let notchWidth: CGFloat
    let peekWidth: CGFloat

    /// Nil when no built-in (notched) display is present.
    init?(screen: NSScreen? = nil) {
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        else { return nil }
        self.screen = screen
        self.topInset = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let notchW = (left > 0 && right > 0)
            ? max(Self.minNotchWidth, screen.frame.width - left - right)
            : Self.fallbackNotchWidth
        self.notchWidth = notchW
        self.peekWidth = max(Self.minPeekWidth, notchW + Self.peekSidePadding)
    }
}

@MainActor
final class NotchPanelController {
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var sticky = false

    var onTap: (() -> Void)?

    private enum Dismissal { case sticky, autoHide, hover }
    private var current: Dismissal = .hover

    func showNeedsYou(_ session: Session) {
        let detail = [session.projectName, session.message].compactMap { $0 }.joined(separator: " · ")
        show(title: "Needs you", detail: detail, state: .needsYou, dismissal: .sticky)
    }

    func showFinished(_ session: Session, duration: TimeInterval) {
        show(title: "Finished", detail: "\(session.projectName) · \(DurationFormat.short(duration))",
             state: .waiting, dismissal: .autoHide)
    }

    /// Shown while the mouse hovers the notch; dismissed on mouse-out unless a
    /// higher-priority sticky alert is already up.
    func showHover(title: String, detail: String, state: AggregateState) {
        show(title: title, detail: detail, state: state, dismissal: .hover)
    }

    func hideHover() {
        if current == .hover { hide() }
    }

    func resolveIfSticky(aggregate: AggregateState) {
        if sticky && aggregate != .needsYou { hide() }
    }

    private func show(title: String, detail: String, state: AggregateState, dismissal: Dismissal) {
        guard UserDefaults.standard.bool(forKey: "notchAlertsEnabled") else { return }
        // Proactive peeks (needs-you / finished) can be turned off separately,
        // leaving hover-to-reveal working.
        if dismissal != .hover, !UserDefaults.standard.bool(forKey: "notchProactiveEnabled") { return }
        guard let metrics = NotchMetrics() else { return }
        // A sticky needs-you alert outranks a finished toast or a hover peek.
        if sticky, dismissal != .sticky { return }

        let wasVisible = panel?.isVisible ?? false
        hideTimer?.invalidate(); hideTimer = nil
        current = dismissal
        self.sticky = (dismissal == .sticky)

        let screen = metrics.screen
        let width = metrics.peekWidth
        let topInset = metrics.topInset                // panel extends up behind the menu bar
        let visibleHeight = NotchMetrics.visibleHeight
        let height = visibleHeight + topInset
        let notchBottom = screen.frame.maxY - topInset
        let finalFrame = NSRect(x: screen.frame.midX - width / 2,
                                y: notchBottom - visibleHeight, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: PeekView(
            title: title, detail: detail, state: state,
            topInset: topInset,
            onTap: { [weak self] in
                self?.onTap?()
                self?.hide()
            }))

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wasVisible {
            panel.setFrame(finalFrame, display: true)   // content swap (e.g. hover updates): no re-animation
        } else {
            panel.alphaValue = 0
            panel.setFrame(reduce ? finalFrame : finalFrame.offsetBy(dx: 0, dy: 12), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduce ? 0.15 : WidgetConstants.peekSlideDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(finalFrame, display: true)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }

        if dismissal == .autoHide {
            hideTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.finishedPeekAutoHide,
                                             repeats: false) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        hideTimer?.invalidate(); hideTimer = nil
        sticky = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above fullscreen apps: .statusBar (25) sits *below* a fullscreen
        // window, so the peek wouldn't show over one. .screenSaver floats above.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

/// Full-width silhouette: square top (which tucks up behind the menu bar, so
/// its corners are hidden and the sides read as filled) and rounded bottom
/// corners. Pure black, so the notch merges into it seamlessly.
struct NotchPeekShape: Shape {
    var cornerRadius: CGFloat = NotchMetrics.cornerRadius

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let br = min(cornerRadius, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h - br))
        p.addArc(center: CGPoint(x: w - br, y: h - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: br, y: h))
        p.addArc(center: CGPoint(x: br, y: h - br), radius: br,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct PeekView: View {
    let title: String
    let detail: String
    let state: AggregateState
    var topInset: CGFloat = 0
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            PeekCritter(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(Font(Theme.monoFont(11)))
                    .foregroundStyle(Color(white: 0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text("click to open")
                .font(Font(Theme.monoFont(10)))
                .foregroundStyle(Color(white: 0.45))
        }
        .padding(.horizontal, 22)
        .padding(.top, topInset + 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(NotchPeekShape().fill(Color.black))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// The peek's critter, animated to mirror the menu bar critter for the same
/// state: walks while working, pulses when Claude needs you, idle otherwise.
/// Colors come from the same `Theme.critterColor` the status item uses.
struct PeekCritter: View {
    let state: AggregateState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (color, opacity) = Theme.critterColor(state: state, darkAppearance: true)
        Group {
            switch state {
            case .working where !reduceMotion:
                TimelineView(.periodic(from: .now, by: WidgetConstants.walkFrameDuration)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate / WidgetConstants.walkFrameDuration)
                    image(step.isMultiple(of: 2) ? .walkA : .walkB, color, opacity)
                }
            case .needsYou where !reduceMotion:
                PulseCritter(color: color, opacity: opacity)
            case .asleep:
                image(.asleep, color, opacity)
            default:
                image(.idle, color, opacity)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func image(_ pose: CritterPose, _ color: NSColor, _ opacity: CGFloat) -> Image {
        Image(nsImage: CritterRenderer.image(pose: pose, color: color, opacity: opacity, pointSize: 24))
    }
}

/// Idle critter with the menu bar's opacity pulse, for the needs-you peek.
private struct PulseCritter: View {
    let color: NSColor
    let opacity: CGFloat
    @State private var dim = false

    var body: some View {
        Image(nsImage: CritterRenderer.image(pose: .idle, color: color, opacity: opacity, pointSize: 24))
            .opacity(dim ? 0.55 : 1.0)
            .animation(.easeInOut(duration: WidgetConstants.pulsePeriod / 2).repeatForever(autoreverses: true),
                       value: dim)
            .onAppear { dim = true }
    }
}

/// Watches the mouse and fires when it enters or leaves the notch region,
/// so the widget can reveal a status peek on hover.
@MainActor
final class NotchHoverController {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: Any?
    private var inside = false
    private var triggerRect: NSRect = .zero   // small: entering here reveals the peek
    private var keepRect: NSRect = .zero       // notch + peek: staying here keeps it up

    var onHoverIn: (() -> Void)?
    var onHoverOut: (() -> Void)?

    func start() {
        recompute()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.update()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.update()
            return event
        }
        // Resolution / display changes move the notch — recompute the hover zones
        // so they don't point at stale coordinates until the next restart.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
    }

    private func recompute() {
        guard let metrics = NotchMetrics() else {
            triggerRect = .zero; keepRect = .zero; return
        }
        let top = metrics.topInset
        let midX = metrics.screen.frame.midX, maxY = metrics.screen.frame.maxY

        // Trigger: the notch itself (a little padded), easy to aim for.
        triggerRect = NSRect(x: midX - metrics.notchWidth / 2 - 24, y: maxY - top - 4,
                             width: metrics.notchWidth + 48, height: top + 4)
        // Keep-alive: the notch plus the whole peek footprint below it, so moving
        // the mouse down onto the peek to click never dismisses it.
        keepRect = NSRect(x: midX - metrics.peekWidth / 2, y: maxY - top - NotchMetrics.visibleHeight,
                          width: metrics.peekWidth, height: top + NotchMetrics.visibleHeight)
    }

    private func update() {
        let loc = NSEvent.mouseLocation
        if !inside, triggerRect.contains(loc) {
            inside = true; onHoverIn?()
        } else if inside, !keepRect.contains(loc) {
            inside = false; onHoverOut?()
        }
    }

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        if let s = screenObserver { NotificationCenter.default.removeObserver(s) }
    }
}
