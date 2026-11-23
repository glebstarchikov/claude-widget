import AppKit
import SwiftUI
import ClaudeWidgetCore

/// The hub's window: borderless, non-activating, never key, so showing it or
/// clicking in it never takes focus from the app Gleb is typing in.
final class HubPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click even though its window is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the hub panel and its three states — hidden, pill, expanded — and
/// decides where it sits and when hover opens and closes it.
///
/// The panel stays ordered front and transparent; it takes mouse events only
/// while the pointer is over the visible pill or hub, so the rest of its frame
/// never blocks clicks on whatever is underneath.
@MainActor
final class HubController {
    private static let openDwell: TimeInterval = 0.15
    /// Longer than the notch dwell so a pill can be clicked before it expands.
    private static let pillDwell: TimeInterval = 0.5
    private static let closeDelay: TimeInterval = 0.3
    private static let closeMargin: CGFloat = 30

    /// Where the content hangs (its top-center), plus areas outside the hub
    /// where the pointer still keeps it open (the notch zone, the critter).
    private struct Placement {
        let midX: CGFloat
        let top: CGFloat
        let keepZones: [NSRect]
    }

    private let model: HubModel
    private let appModel: AppModel
    private var panel: HubPanel!
    private var notch: NotchMetrics?
    /// The now-playing strip while it shows: it counts as the notch.
    private var stripFrame: NSRect?
    private var placement: Placement?
    private var hubHeight: CGFloat = 0
    private var pillSize = HubLayout.pillSize
    private var dwell: (zone: NSRect, task: Task<Void, Never>)?
    private var closeTask: Task<Void, Never>?
    private var pillHideTask: Task<Void, Never>?
    /// Hover-close applies once the pointer has been over the hub; a hub opened
    /// by clicking the critter waits for that, or for a click elsewhere.
    private var hoverCloseArmed = false
    /// A click that started in the hub is still held: don't close under it.
    private var pressInHub = false
    private var observers: [Any] = []
    /// Called each time the hub opens.
    var onOpen: (() -> Void)?
    /// Called each time the hub closes.
    var onClose: (() -> Void)?

    init(model: HubModel, appModel: AppModel) {
        self.model = model
        self.appModel = appModel
    }

    func start() {
        panel = Self.makePanel()
        let host = FirstClickHostingView(rootView: HubView(
            model: model,
            onHubHeightChange: { [weak self] height in self?.hubHeight = height },
            onPillSizeChange: { [weak self] size in self?.pillSize = size }))
        host.sizingOptions = []   // the controller sizes the panel, never SwiftUI
        panel.contentView = host
        notch = NotchMetrics()
        if let place = notch.map(notchPlacement) ?? pointerPlacement() { position(at: place) }
        panel.orderFrontRegardless()

        observers.append(contentsOf: [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.track() },
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.track(); return event
            },
            // Clicks on the hub reach this app; a click anywhere else is a global event.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.close()
            },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.mouseButton(event); return event
            },
        ].compactMap { $0 })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    // MARK: - Entry points

    /// Left click on the critter: open the hub (under the notch on a notched
    /// screen, under the critter elsewhere), or close it if it's open.
    func toggleFromStatusItem(_ button: NSStatusBarButton) {
        if model.expanded { close(); return }
        guard let window = button.window, let screen = window.screen else { return }
        let critter = window.frame
        if let notch = NotchMetrics(screen: screen) {
            let place = notchPlacement(notch)
            expand(at: Placement(midX: place.midX, top: place.top, keepZones: place.keepZones + [critter]),
                   byHover: false)
        } else {
            let half = HubLayout.width / 2 + HubLayout.gapBelowMenuBar
            let midX = min(max(critter.midX, screen.frame.minX + half), screen.frame.maxX - half)
            expand(at: Placement(midX: midX, top: critter.minY - HubLayout.gapBelowMenuBar, keepZones: [critter]),
                   byHover: false)
        }
    }

    /// For the `--show-hub` launch argument: opens the hub under the notch (or
    /// top-center of the pointer's screen) until a click elsewhere.
    func showExpanded() {
        guard let place = notch.map(notchPlacement) ?? pointerPlacement() else { return }
        expand(at: place, byHover: false)
    }

    /// A click on the now-playing strip: opens the hub under the notch.
    func openFromNotch() {
        guard let notch else { return }
        expand(at: notchPlacement(notch), byHover: false)
    }

    /// The now-playing strip's frame while it shows, nil while it doesn't
    /// (NotchStripController). Dwelling on it opens the hub, and a hub opened
    /// while it shows stays open over it.
    func setStripFrame(_ frame: NSRect?) {
        stripFrame = frame
    }

    func showPill(_ pill: Pill) {
        guard appModel.notchProactive else { return }
        // A needs-you pill outranks a finished one.
        if case .finished = pill, case .needsYou? = model.pill { return }
        pillHideTask?.cancel(); pillHideTask = nil
        // Nothing on screen yet: put the pill on the screen the pointer is on.
        if !model.expanded, model.pill == nil, let place = pointerPlacement() {
            placement = place
            position(at: place)
        }
        panel.orderFrontRegardless()
        model.pill = pill
        if case .finished = pill { schedulePillHide() }
        updateMouseGate()
        logFrame()
    }

    /// Drops pills that no longer apply: a needs-you pill once its session
    /// stops needing you (and no permission request is live), a finished pill
    /// once its session is gone.
    func resolvePills(aggregate: AggregateState) {
        guard let pill = model.pill else { return }
        switch pill {
        case .needsYou(let id):
            if !model.pending.isEmpty { return }   // it shows the oldest request
            let stillNeeded = aggregate == .needsYou
                && model.sessions.contains { $0.sessionId == id && $0.state == .needsYou }
            if stillNeeded { return }
            // Another session may still need you: its pill takes over.
            if aggregate == .needsYou, let other = model.sessions.first(where: { $0.state == .needsYou }) {
                model.pill = .needsYou(sessionId: other.sessionId)
            } else {
                model.pill = nil
            }
        case .finished(let id, _):
            if model.sessions.contains(where: { $0.sessionId == id }) { return }
            pillHideTask?.cancel(); pillHideTask = nil
            model.pill = nil
        }
        updateMouseGate()
    }

    /// Keeps the pill in step with `model.pending` (ApprovalCoordinator): it shows
    /// the oldest request. When the last one goes, one Gleb dealt with (`dismissing`
    /// its session) takes its pill along; otherwise the plain needs-you pill stays
    /// while the session still needs you.
    func approvalsChanged(dismissing sessionId: String?) {
        if let first = model.pending.first {
            showPill(.needsYou(sessionId: first.request.sessionId))
            return
        }
        if let sessionId, case .needsYou(sessionId)? = model.pill {
            model.pill = model.sessions
                .first { $0.state == .needsYou && $0.sessionId != sessionId }
                .map { .needsYou(sessionId: $0.sessionId) }
        }
        resolvePills(aggregate: Aggregator.aggregate(model.sessions))
        updateMouseGate()
    }

    /// The pill's Review button: opens the hub where the pill is, scrolled to the request.
    func review(approvalId: String) {
        guard let place = placement ?? notch.map(notchPlacement) ?? pointerPlacement() else { return }
        model.revealApprovalId = approvalId
        expand(at: place, byHover: false)
    }

    /// Closes the expanded hub; a pending pill shows again.
    func close() {
        guard model.expanded else { return }
        dwell?.task.cancel(); dwell = nil
        closeTask?.cancel(); closeTask = nil
        pressInHub = false
        model.expanded = false
        model.revealApprovalId = nil
        updateMouseGate()
        onClose?()
    }

    // MARK: - Hover

    private func track() {
        let p = NSEvent.mouseLocation
        updateMouseGate(p)

        if model.expanded {
            if keepZones.contains(where: { Self.pointer(p, in: $0) }) {
                closeTask?.cancel(); closeTask = nil
                // Arm only over the hub itself: the critter is a keep zone too, and
                // a hub opened from it must survive the trip from the critter.
                if let hub = hubFrame, Self.pointer(p, in: hub) { hoverCloseArmed = true }
            } else if hoverCloseArmed, closeTask == nil {
                closeTask = after(Self.closeDelay) { [weak self] in self?.closeIfAway() }
            }
            return
        }

        if let pill = pillFrame, Self.pointer(p, in: pill), let placement {
            // A pill with Allow/Deny stays put under the pointer; Review opens the hub.
            // A dwell begun over a plain pill is vetoed if a request arrives meanwhile.
            if showsApprovalPill { dwell?.task.cancel(); dwell = nil }
            else {
                startDwell(in: pill, for: Self.pillDwell) { [weak self] in
                    self?.showsApprovalPill == false ? placement : nil
                }
            }
        } else if appModel.hubHoverEnabled, let notch, let zone = notchZone, Self.pointer(p, in: zone) {
            startDwell(in: zone, for: Self.openDwell) { [weak self] in
                guard let self, !Self.activeAppIsFullscreen(on: notch.screen) else { return nil }
                return self.notchPlacement(notch)
            }
        } else {
            dwell?.task.cancel(); dwell = nil
        }
    }

    /// Opens the hub if the pointer is still in `zone` after `delay`. Passing
    /// through faster than that never opens it. `place` may veto by returning nil.
    private func startDwell(in zone: NSRect, for delay: TimeInterval,
                            place: @escaping @MainActor () -> Placement?) {
        if dwell?.zone == zone { return }
        dwell?.task.cancel()
        let task = after(delay) { [weak self] in
            guard let self else { return }
            self.dwell = nil
            guard Self.pointer(NSEvent.mouseLocation, in: zone), let place = place() else { return }
            self.expand(at: place, byHover: true)
        }
        dwell = (zone, task)
    }

    private func closeIfAway() {
        closeTask = nil
        guard model.expanded, !pressInHub else { return }   // mouse-up re-runs track()
        if keepZones.contains(where: { Self.pointer(NSEvent.mouseLocation, in: $0) }) { return }
        close()
    }

    private func mouseButton(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            pressInHub = event.window === panel
        } else if pressInHub {
            pressInHub = false
            track()
        }
    }

    // MARK: - States

    private func expand(at place: Placement, byHover: Bool) {
        guard !model.expanded else { return }
        dwell?.task.cancel(); dwell = nil
        placement = place
        position(at: place)
        hoverCloseArmed = byHover
        panel.orderFrontRegardless()
        model.expanded = true
        onOpen?()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        updateMouseGate()
        logFrame()
    }

    private func schedulePillHide() {
        pillHideTask = after(WidgetConstants.finishedPeekAutoHide) { [weak self] in
            guard let self, case .finished? = self.model.pill else { return }
            self.pillHideTask = nil
            // Never pull a pill out from under the pointer; try again later.
            if !self.model.expanded, let pill = self.pillFrame, Self.pointer(NSEvent.mouseLocation, in: pill) {
                self.schedulePillHide()
                return
            }
            self.model.pill = nil
            self.updateMouseGate()
        }
    }

    private func screensChanged() {
        close()
        notch = NotchMetrics()
        if model.pill != nil, let place = pointerPlacement() {
            placement = place
            position(at: place)
        }
        updateMouseGate()
    }

    // MARK: - Geometry

    private func notchPlacement(_ notch: NotchMetrics) -> Placement {
        Placement(midX: notch.screen.frame.midX,
                  top: notch.screen.frame.maxY - notch.topInset - HubLayout.gapBelowMenuBar,
                  keepZones: [notch.hoverZone] + [stripFrame].compactMap { $0 })
    }

    /// Dwelling here opens the hub: the notch's hover zone, widened by the strip while it shows.
    private var notchZone: NSRect? {
        guard let notch else { return nil }
        return stripFrame.map { notch.hoverZone.union($0) } ?? notch.hoverZone
    }

    /// Under the notch if the pointer's screen has one, otherwise top-center
    /// under that screen's menu bar.
    private func pointerPlacement() -> Placement? {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main
        else { return nil }
        if let notch = NotchMetrics(screen: screen) { return notchPlacement(notch) }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let top = screen.frame.maxY - (menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
        return Placement(midX: screen.frame.midX, top: top - HubLayout.gapBelowMenuBar, keepZones: [])
    }

    private func position(at place: Placement) {
        let size = HubLayout.panelSize
        panel.setFrame(NSRect(x: place.midX - size.width / 2, y: place.top + HubLayout.margin - size.height,
                              width: size.width, height: size.height), display: false)
    }

    private var hubFrame: NSRect? {
        guard let placement else { return nil }
        return NSRect(x: placement.midX - HubLayout.width / 2, y: placement.top - hubHeight,
                      width: HubLayout.width, height: hubHeight)
    }

    /// The needs-you pill is showing a permission request (HubView).
    private var showsApprovalPill: Bool {
        if case .needsYou? = model.pill { return !model.pending.isEmpty }
        return false
    }

    /// Where the pill is (or returns to once the hub closes).
    private var pillFrame: NSRect? {
        guard let placement, let pill = model.pill,
              showsApprovalPill || model.sessions.contains(where: { $0.sessionId == pill.sessionId })
        else { return nil }
        return NSRect(x: placement.midX - pillSize.width / 2, y: placement.top - pillSize.height,
                      width: pillSize.width, height: pillSize.height)
    }

    private var keepZones: [NSRect] {
        var zones = placement?.keepZones ?? []
        if let hub = hubFrame { zones.append(hub.insetBy(dx: -Self.closeMargin, dy: -Self.closeMargin)) }
        if let pill = pillFrame { zones.append(pill) }
        return zones
    }

    /// Pointer hit test. Unlike `NSRect.contains`, counts the top edge as
    /// inside: a pointer pushed against the top of the screen sits at `maxY`.
    private static func pointer(_ p: NSPoint, in rect: NSRect) -> Bool {
        NSMouseInRect(p, rect, false)
    }

    /// The panel takes mouse events only over what's visible.
    private func updateMouseGate(_ p: NSPoint = NSEvent.mouseLocation) {
        let visible = model.expanded ? hubFrame : pillFrame
        let interactive = visible.map { Self.pointer(p, in: $0) } ?? false
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    /// Whether the active app is fullscreen with a window on `screen`. Checked
    /// only when a notch dwell completes, and by the now-playing strip when the
    /// space or front app changes, so the window list isn't polled.
    static func activeAppIsFullscreen(on screen: NSScreen) -> Bool {
        guard NSApp.currentSystemPresentationOptions.contains(.fullScreen),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Window-list bounds have a top-left origin on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        let screenRect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return false }
            return bounds.width >= screenRect.width && screenRect.contains(CGPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    // MARK: - Plumbing

    /// The hub's panel; the now-playing strip uses the same recipe.
    static func makePanel() -> HubPanel {
        let panel = HubPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        // Float above OTHER apps' fullscreen windows. What matters:
        //  • .screenSaver level (.statusBar/25 sits *below* a fullscreen window).
        //  • .canJoinAllSpaces so the panel joins the fullscreen app's space.
        //  • NOT .fullScreenAuxiliary — with .canJoinAllSpaces it shows on every
        //    space but *behind* another app's fullscreen window (Apple dev forums).
        //  • NOT .stationary — it pins the window to the base/desktop space, which
        //    fights .canJoinAllSpaces and keeps it off the fullscreen space.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false   // the panel stays ordered front for the app's lifetime
        panel.ignoresMouseEvents = true
        return panel
    }

    /// Runs `action` on the main actor after `delay`, unless cancelled first.
    private func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { action() }
        }
    }

    /// Debug builds print the panel frame in `screencapture -R` coordinates
    /// (top-left origin) for screenshots. The content hangs from its top-center.
    private func logFrame() {
        #if DEBUG
        let f = panel.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        print("HUB frame=\(Int(f.minX)),\(Int(primaryHeight - f.maxY)),\(Int(f.width)),\(Int(f.height))"
              + " state=\(model.expanded ? "hub" : "pill")")
        fflush(stdout)
        #endif
    }
}
