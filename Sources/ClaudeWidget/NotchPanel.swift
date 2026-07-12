import AppKit
import SwiftUI
import ClaudeWidgetCore

@MainActor
final class NotchPanelController {
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var sticky = false

    var onTap: (() -> Void)?

    func showNeedsYou(_ session: Session) {
        let detail = [session.projectName, session.message].compactMap { $0 }.joined(separator: " · ")
        show(title: "Needs you", detail: detail, color: Theme.claudeOrange, sticky: true)
    }

    func showFinished(_ session: Session, duration: TimeInterval) {
        show(title: "Finished", detail: "\(session.projectName) · \(Self.format(duration))",
             color: Theme.accentDark, sticky: false)
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

    private func show(title: String, detail: String, color: NSColor, sticky: Bool) {
        guard UserDefaults.standard.bool(forKey: "notchAlertsEnabled") else { return }
        guard let screen = builtInScreen() else { return }

        hideTimer?.invalidate(); hideTimer = nil
        self.sticky = sticky

        let width: CGFloat = 340
        let height: CGFloat = 56
        let notchBottom = screen.frame.maxY - screen.safeAreaInsets.top
        let finalFrame = NSRect(x: screen.frame.midX - width / 2,
                                y: notchBottom - height, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: PeekView(
            title: title, detail: detail, critterColor: Color(nsColor: color),
            onTap: { [weak self] in
                self?.onTap?()
                self?.hide()
            }))

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.setFrame(reduce ? finalFrame : finalFrame.offsetBy(dx: 0, dy: 12), display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.15 : WidgetConstants.peekSlideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        if !sticky {
            hideTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.finishedPeekAutoHide,
                                             repeats: false) { _ in
                Task { @MainActor in self.hide() }
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
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

struct PeekView: View {
    let title: String
    let detail: String
    let critterColor: Color
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: CritterRenderer.image(
                pose: .idle,
                color: NSColor(critterColor),
                opacity: 1.0, pointSize: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.panelFg))
                Text(detail)
                    .font(Font(Theme.monoFont(11)))
                    .foregroundStyle(Color(nsColor: Theme.panelFaint))
                    .lineLimit(1)
            }
            Spacer()
            Text("click to open")
                .font(Font(Theme.monoFont(10)))
                .foregroundStyle(Color(nsColor: Theme.panelFaint))
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: 340, height: 56, alignment: .center)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(Color(nsColor: Theme.panelBg))
                .overlay(
                    UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                        .strokeBorder(Color(nsColor: Theme.panelBorder), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
