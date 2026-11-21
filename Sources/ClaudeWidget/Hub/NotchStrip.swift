import AppKit
import Combine
import SwiftUI
import os
import ClaudeWidgetCore

/// What the strip's view shows, kept by NotchStripController.
@MainActor
final class NotchStripState: ObservableObject {
    @Published var visible = false
    @Published var notchWidth: CGFloat = 0
    @Published var topInset: CGFloat = 0
    @Published var artwork: NSImage?
    @Published var playing = false
}

/// While music plays and the hub is closed, the black notch widens: the artwork on
/// the left flank, four level bars on the right (spec §3.4). Its own panel in the
/// menu bar band of the notched screen, with the hub panel's recipe. It gives way
/// to the hub, any pill and a fullscreen app, and counts as the notch for hover
/// and clicks while it shows (HubController.setStripFrame).
@MainActor
final class NotchStripController {
    private let model: HubModel
    private let appModel: AppModel
    private let hub: HubController
    private let state = NotchStripState()
    private var panel: HubPanel!
    private var notch: NotchMetrics?
    private var fullscreen = false
    /// nil until the first decision, so that one is logged too.
    private var visible: Bool?
    private var graceTask: Task<Void, Never>?
    private var fullscreenRecheck: Task<Void, Never>?
    private var subscriptions: [AnyCancellable] = []
    private var observers: [Any] = []

    init(model: HubModel, appModel: AppModel, hub: HubController) {
        self.model = model
        self.appModel = appModel
        self.hub = hub
    }

    func start() {
        panel = HubController.makePanel()
        let host = FirstClickHostingView(rootView: NotchStripView(state: state) { [weak self] in
            self?.hub.openFromNotch()
        })
        host.sizingOptions = []   // the controller sizes the panel, never SwiftUI
        panel.contentView = host
        measure()
        fullscreen = readFullscreen()

        // objectWillChange fires before the change; the hop to the next main-queue
        // turn reads the new values.
        subscriptions = [model.objectWillChange, appModel.objectWillChange].map {
            $0.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceOrAppChanged() }
            })
        }
        update()
    }

    // MARK: - Deciding

    private func update() {
        let inputs = NowPlayingRules.StripInputs(
            track: model.nowPlaying, pausedAt: model.nowPlayingPausedAt, now: Date(),
            hubOpen: model.expanded, pillUp: model.pill != nil, fullscreen: fullscreen,
            hasNotch: notch != nil, enabled: appModel.nowPlayingEnabled,
            notchEnabled: appModel.nowPlayingNotchEnabled)
        let show = NowPlayingRules.showsStrip(inputs)
        scheduleGraceEnd(inputs)
        // Only while there's a track: one that stops keeps its look while the strip leaves.
        if let track = inputs.track {
            if state.artwork !== model.nowPlayingArtwork { state.artwork = model.nowPlayingArtwork }
            if state.playing != track.isPlaying { state.playing = track.isPlaying }
        }
        guard show != visible else { return }
        visible = show
        state.visible = show
        panel.ignoresMouseEvents = !show
        hub.setStripFrame(show ? panel.frame : nil)
        if show {
            Logger.nowPlaying.notice("strip shown")
        } else {
            Logger.nowPlaying.notice("strip hidden: \(Self.reason(inputs), privacy: .public)")
        }
    }

    /// A pause keeps the strip for `pauseGrace`: decide again when that runs out.
    private func scheduleGraceEnd(_ inputs: NowPlayingRules.StripInputs) {
        graceTask?.cancel()
        graceTask = nil
        guard let track = inputs.track, !track.isPlaying, let pausedAt = inputs.pausedAt else { return }
        let remaining = pausedAt.addingTimeInterval(NowPlayingRules.pauseGrace).timeIntervalSince(inputs.now)
        guard remaining > 0 else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// Why the strip is hidden, for the log: the first blocker in `showsStrip`'s
    /// order. Fixed words only, never anything about the track.
    private static func reason(_ inputs: NowPlayingRules.StripInputs) -> String {
        if !inputs.enabled || !inputs.notchEnabled { return "setting" }
        if !inputs.hasNotch { return "no notch" }
        if inputs.hubOpen { return "hub open" }
        if inputs.pillUp { return "pill" }
        if inputs.fullscreen { return "fullscreen" }
        return inputs.track == nil ? "nothing playing" : "paused"
    }

    // MARK: - Screen and fullscreen

    /// The notch plus a flank each side as wide as the menu bar is tall, flush with
    /// the top of the notched screen. No notched screen: no panel.
    private func measure() {
        notch = NotchMetrics()
        guard let notch else { panel.orderOut(nil); return }
        let width = notch.notchWidth + 2 * notch.topInset
        let screen = notch.screen.frame
        panel.setFrame(NSRect(x: screen.midX - width / 2, y: screen.maxY - notch.topInset,
                              width: width, height: notch.topInset), display: false)
        state.notchWidth = notch.notchWidth
        state.topInset = notch.topInset
        panel.orderFrontRegardless()
    }

    private func screensChanged() {
        measure()
        fullscreen = readFullscreen()
        update()
        if visible == true { hub.setStripFrame(panel.frame) }   // the panel may have moved
    }

    /// Re-read when the space or the front app changes, never polled.
    private func spaceOrAppChanged() {
        fullscreen = readFullscreen()
        update()
        // The window list can lag the notification while a fullscreen space animates
        // in or out; one more read a moment later settles it.
        fullscreenRecheck?.cancel()
        fullscreenRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.fullscreen = self.readFullscreen()
            self.update()
        }
    }

    private func readFullscreen() -> Bool {
        notch.map { HubController.activeAppIsFullscreen(on: $0.screen) } ?? false
    }
}

/// The black band: the notch plus a flank each side, artwork on the left, level
/// bars on the right. It grows out of the notch with the hub's spring, or fades
/// with Reduce Motion. A click opens the hub.
struct NotchStripView: View {
    static let cornerRadius: CGFloat = 10

    @ObservedObject var state: NotchStripState
    let onTap: () -> Void

    @ObservedObject private var themeStore = ThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fullWidth: CGFloat { state.notchWidth + 2 * state.topInset }

    var body: some View {
        ZStack {
            if state.visible {
                band.transition(reduceMotion ? .opacity : .modifier(
                    active: Reveal(width: state.notchWidth), identity: Reveal(width: fullWidth)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        // The hub's animations (HubView).
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.75),
                   value: state.visible)
    }

    private var band: some View {
        HStack(spacing: 0) {
            StripArtwork(image: state.artwork, size: max(16, state.topInset - 14))
                .frame(width: state.topInset)
            Spacer(minLength: 0)   // the notch
            LevelBars(playing: state.playing, maxHeight: state.topInset - 16,
                      color: Color(nsColor: Theme.accent(dark: true)))
                .frame(width: state.topInset)
        }
        .frame(width: fullWidth, height: state.topInset)
        .background(.black)
        .clipShape(StripShape(width: fullWidth))
        // A tap gesture, not a Button: the panel is never key (NowPlayingModule).
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

/// Shows the middle `width` points of the band, so it grows out of the notch.
private struct Reveal: ViewModifier {
    let width: CGFloat
    func body(content: Content) -> some View {
        content.clipShape(StripShape(width: width))
    }
}

/// Flush with the top, bottom corners rounded like the notch's, `width` wide and
/// centered. Clamped to its frame, so the spring's overshoot never squares the corners.
private struct StripShape: Shape {
    var width: CGFloat

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = min(width, rect.width)
        let r = NotchStripView.cornerRadius
        return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous)
            .path(in: CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height))
    }
}

private struct StripArtwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Four decorative bars, not audio levels (those would need a permission). They
/// move while playing, rest low when paused, and hold still at uneven heights
/// with Reduce Motion.
private struct LevelBars: View {
    private static let count = 4
    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2
    private static let restHeight: CGFloat = 3
    private static let stillLevels: [Double] = [0.55, 0.9, 0.4, 0.7]
    /// Radians per second and offsets, so no two bars move in step.
    private static let speeds: [Double] = [7.3, 9.1, 6.2, 8.4]
    private static let phases: [Double] = [0, 1.7, 3.1, 4.6]

    let playing: Bool
    let maxHeight: CGFloat
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = playing && !reduceMotion
        // 30 fps is plenty for 4 small bars, and they may run for hours.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(0..<Self.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: Self.barWidth / 2)
                        .fill(color)
                        .frame(width: Self.barWidth, height: height(i, at: context.date, moving: moving))
                }
            }
            .frame(height: maxHeight, alignment: .bottom)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: playing)
    }

    private func height(_ i: Int, at date: Date, moving: Bool) -> CGFloat {
        guard playing else { return Self.restHeight }
        let level: Double
        if moving {
            // A slow swell plus a quicker flicker, together within 0...1.
            let t = date.timeIntervalSinceReferenceDate
            level = 0.5 + 0.3 * sin(t * Self.speeds[i] + Self.phases[i])
                + 0.2 * sin(t * Self.speeds[i] * 2.3 + Self.phases[i] * 1.9)
        } else {
            level = Self.stillLevels[i]
        }
        return Self.restHeight + (maxHeight - Self.restHeight) * CGFloat(level)
    }
}
