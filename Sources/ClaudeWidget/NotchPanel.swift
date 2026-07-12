import AppKit
import SwiftUI
import ClaudeWidgetCore

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
        show(title: "Needs you", detail: detail, color: Theme.claudeOrange, dismissal: .sticky)
    }

    func showFinished(_ session: Session, duration: TimeInterval) {
        show(title: "Finished", detail: "\(session.projectName) · \(Self.format(duration))",
             color: Theme.accentDark, dismissal: .autoHide)
    }

    /// Shown while the mouse hovers the notch; dismissed on mouse-out unless a
    /// higher-priority sticky alert is already up.
    func showHover(title: String, detail: String, color: NSColor) {
        show(title: title, detail: detail, color: color, dismissal: .hover)
    }

    func hideHover() {
        if current == .hover { hide() }
    }

    func resolveIfSticky(aggregate: AggregateState) {
        if sticky && aggregate != .needsYou { hide() }
    }

    static func format(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// The notch's pixel width, derived from the menu-bar areas flanking it.
    /// Falls back to a typical 14"/16" notch if the areas aren't reported.
    private func notchWidth(for screen: NSScreen) -> CGFloat {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        if left > 0, right > 0 {
            return max(120, screen.frame.width - left - right)
        }
        return 200
    }

    private func show(title: String, detail: String, color: NSColor, dismissal: Dismissal) {
        guard UserDefaults.standard.bool(forKey: "notchAlertsEnabled") else { return }
        // Proactive peeks (needs-you / finished) can be turned off separately,
        // leaving hover-to-reveal working.
        if dismissal != .hover, !UserDefaults.standard.bool(forKey: "notchProactiveEnabled") { return }
        guard let screen = builtInScreen() else { return }
        // A sticky needs-you alert outranks a finished toast or a hover peek.
        if sticky, dismissal != .sticky { return }

        let wasVisible = panel?.isVisible ?? false
        hideTimer?.invalidate(); hideTimer = nil
        current = dismissal
        self.sticky = (dismissal == .sticky)

        let notchW = notchWidth(for: screen)
        let width = max(340, notchW + 120)
        let topInset = screen.safeAreaInsets.top       // panel extends up behind the menu bar
        let visibleHeight: CGFloat = 58
        let height = visibleHeight + topInset
        let notchBottom = screen.frame.maxY - topInset
        let finalFrame = NSRect(x: screen.frame.midX - width / 2,
                                y: notchBottom - visibleHeight, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: PeekView(
            title: title, detail: detail, critterColor: Color(nsColor: color),
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
        panel.level = .statusBar
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
    var cornerRadius: CGFloat = 20

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
    let critterColor: Color
    var topInset: CGFloat = 0
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: CritterRenderer.image(
                pose: .idle, color: NSColor(critterColor), opacity: 1.0, pointSize: 24))
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
        .background(NotchPeekShape(cornerRadius: 20).fill(Color.black))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Watches the mouse and fires when it enters or leaves the notch region,
/// so the widget can reveal a status peek on hover.
@MainActor
final class NotchHoverController {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var inside = false
    private var triggerRect: NSRect = .zero   // small: entering here reveals the peek
    private var keepRect: NSRect = .zero       // notch + peek: staying here keeps it up

    var onHoverIn: (() -> Void)?
    var onHoverOut: (() -> Void)?

    func start() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return }
        let top = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let notchW = (left > 0 && right > 0) ? max(120, screen.frame.width - left - right) : 200
        let peekW = max(340, notchW + 120)
        let visibleHeight: CGFloat = 58
        let midX = screen.frame.midX, maxY = screen.frame.maxY

        // Trigger: the notch itself (a little padded), easy to aim for.
        triggerRect = NSRect(x: midX - notchW / 2 - 24, y: maxY - top - 4,
                             width: notchW + 48, height: top + 4)
        // Keep-alive: the notch plus the whole peek footprint below it, so moving
        // the mouse down onto the peek to click never dismisses it.
        keepRect = NSRect(x: midX - peekW / 2, y: maxY - top - visibleHeight,
                          width: peekW, height: top + visibleHeight)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.update()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.update()
            return event
        }
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
    }
}
