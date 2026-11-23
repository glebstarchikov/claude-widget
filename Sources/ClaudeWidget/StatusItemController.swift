import AppKit
import ClaudeWidgetCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var aggregate: AggregateState = .asleep
    private var walkTimer: Timer?
    private var blinkWorkItem: DispatchWorkItem?
    private var walkFrameA = true
    private var appearanceObservation: NSKeyValueObservation?

    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var button: NSStatusBarButton? { statusItem.button }

    override init() {
        super.init()
        statusItem.button?.wantsLayer = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.render(pose: self?.currentBasePose ?? .idle) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyState(.asleep)
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            onRightClick?()
        } else {
            onClick?()
        }
    }

    /// Shows `menu` under the status item. Attached only for the duration of the
    /// click so left-click keeps its custom action.
    func showMenu(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func motionPreferenceChanged() {
        Task { @MainActor in self.applyState(self.aggregate) }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var currentBasePose: CritterPose {
        switch aggregate {
        case .asleep: return .asleep
        case .working: return reduceMotion ? .idle : (walkFrameA ? .walkA : .walkB)
        default: return .idle
        }
    }

    func applyState(_ state: AggregateState) {
        aggregate = state
        walkTimer?.invalidate(); walkTimer = nil
        blinkWorkItem?.cancel(); blinkWorkItem = nil
        stopPulse()

        switch state {
        case .asleep:
            render(pose: .asleep)
        case .ready, .waiting:
            render(pose: .idle)
            if !reduceMotion { scheduleBlink() }
        case .working:
            walkFrameA = true
            render(pose: currentBasePose)
            if !reduceMotion {
                walkTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.walkFrameDuration,
                                                 repeats: true) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.walkFrameA.toggle()
                        self.render(pose: self.currentBasePose)
                    }
                }
            }
        case .needsYou:
            render(pose: .idle)
            if !reduceMotion { startPulse() }
        }
    }

    private func scheduleBlink() {
        let delay = TimeInterval.random(in: WidgetConstants.blinkIntervalRange)
        let showBlink = DispatchWorkItem { [weak self] in
            guard let self, self.aggregate == .ready || self.aggregate == .waiting else { return }
            self.render(pose: .blink)
            let hideBlink = DispatchWorkItem { [weak self] in
                guard let self, self.aggregate == .ready || self.aggregate == .waiting else { return }
                self.render(pose: .idle)
                self.scheduleBlink()
            }
            self.blinkWorkItem = hideBlink
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: hideBlink)
        }
        blinkWorkItem = showBlink
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: showBlink)
    }

    private func startPulse() {
        guard let layer = statusItem.button?.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.55
        animation.duration = WidgetConstants.pulsePeriod / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "pulse")
    }

    private func stopPulse() {
        statusItem.button?.layer?.removeAnimation(forKey: "pulse")
        statusItem.button?.layer?.opacity = 1
    }

    /// Re-renders the current pose (a theme or hat change) without touching timers or the pulse.
    func refresh() {
        render(pose: currentBasePose)
    }

    private func render(pose: CritterPose) {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (color, opacity) = Theme.critterColor(state: aggregate, darkAppearance: dark)
        button.image = CritterRenderer.image(pose: pose, color: color, opacity: opacity,
                                          hat: ThemeStore.shared.hatOn, badge: aggregate == .needsYou)
    }
}
