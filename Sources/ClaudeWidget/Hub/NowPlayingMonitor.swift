import AppKit
import Foundation
import os
import MediaRemoteAdapter
import ClaudeWidgetCore

extension Logger {
    static let nowPlaying = Logger(subsystem: "com.glebstarchikov.claude-widget", category: "nowPlaying")
}

/// Keeps HubModel's now-playing fields current from the adapter's listener (a perl
/// child), restarting it with backoff and giving up if it keeps dying. Nothing
/// about the track is ever logged.
@MainActor
final class NowPlayingMonitor {
    private let model: HubModel
    private var controller: MediaController?
    private var restartTask: Task<Void, Never>?
    private var exits: [Date] = []
    private var previewing = false
    var onUnavailableChange: (Bool) -> Void = { _ in }

    init(model: HubModel) { self.model = model }

    func start() {
        guard controller == nil, restartTask == nil, !previewing else { return }
        if let preview = UserDefaults.standard.string(forKey: "nowPlayingPreview"), preview == "YES" || preview == "sparse" {
            previewing = true
            publishPreview(sparse: preview == "sparse")
            Logger.nowPlaying.notice("started (preview)")
            return
        }
        Logger.nowPlaying.notice("started")
        listen()
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        controller?.stopListening()
        controller = nil
        previewing = false
        exits = []
        clear()
        onUnavailableChange(false)
        Logger.nowPlaying.notice("stopped")
    }

    func send(_ command: NowPlayingCommand) {
        let now = Date()
        switch command {
        case .togglePlayPause:
            let previous = model.nowPlaying
            let next = previous?.toggledPlayback(at: now)
            model.nowPlaying = next
            model.nowPlayingPausedAt = NowPlayingRules.pausedAt(
                previous: previous, next: next, previousPausedAt: model.nowPlayingPausedAt, now: now)
            controller?.togglePlayPause()
        case .previous: controller?.previousTrack()
        case .next: controller?.nextTrack()
        }
    }

    func openApp() {
        guard !previewing, let track = model.nowPlaying else { return }
        activateOwnerApp(track.bundleId, pid: track.pid)
    }

    // MARK: - Listener

    private func listen() {
        let controller = MediaController()
        // Only the current controller is heard: a payload or an exit queued before
        // stop() or a restart dropped it must not republish a track or schedule a restart.
        controller.onTrackInfoReceived = { [weak self, weak controller] info in
            MainActor.assumeIsolated {
                guard let self, let controller, self.controller === controller else { return }
                self.received(info)
            }
        }
        controller.onListenerTerminated = { [weak self, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let controller, self.controller === controller else { return }
                self.listenerExited()
            }
        }
        controller.onDecodingError = { [weak self, weak controller] error, data in
            MainActor.assumeIsolated {
                guard let self, let controller, self.controller === controller else { return }
                Logger.nowPlaying.error("could not decode an update (\(data.count, privacy: .public) bytes)")
            }
        }
        self.controller = controller
        controller.startListening()
    }

    private func received(_ info: TrackInfo?) {
        let now = Date()
        let payload = info?.payload
        let track = payload.flatMap {
            NowPlaying(title: $0.title, artist: $0.artist, album: $0.album, appName: $0.applicationName,
                       bundleId: $0.bundleIdentifier, pid: $0.PID, isPlaying: $0.isPlaying,
                       durationMicros: $0.durationMicros, elapsedMicros: $0.elapsedTimeMicros,
                       timestampMicros: $0.timestampEpochMicros, rate: $0.playbackRate, receivedAt: now)
        }
        let previous = model.nowPlaying
        model.nowPlayingPausedAt = NowPlayingRules.pausedAt(
            previous: previous, next: track, previousPausedAt: model.nowPlayingPausedAt, now: now)
        model.nowPlaying = track
        model.nowPlayingArtwork = track == nil ? nil : payload?.artwork
    }

    private func listenerExited() {
        let now = Date()
        exits.append(now)
        controller = nil
        switch NowPlayingRules.restart(exits: exits, now: now) {
        case .after(let delay):
            Logger.nowPlaying.error("listener exited; restarting in \(Int(delay), privacy: .public) s")
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.restartTask = nil
                Logger.nowPlaying.notice("restarting listener")
                self.listen()
            }
        case .giveUp:
            Logger.nowPlaying.error("listener keeps exiting; giving up")
            clear()
            onUnavailableChange(true)
        }
    }

    private func clear() {
        model.nowPlaying = nil
        model.nowPlayingArtwork = nil
        model.nowPlayingPausedAt = nil
    }

    // MARK: - Preview (-nowPlayingPreview YES|sparse)

    private func publishPreview(sparse: Bool) {
        let now = Date()
        model.nowPlaying = NowPlaying(
            title: "Preview Track", artist: sparse ? nil : "Claude Widget", album: nil,
            appName: sparse ? "Google Chrome" : "Music", bundleId: nil, pid: nil, isPlaying: true,
            durationMicros: sparse ? nil : 245e6, elapsedMicros: sparse ? 0 : 61e6,
            timestampMicros: nil, rate: 1, receivedAt: now)
        model.nowPlayingArtwork = sparse ? nil : Self.previewArtwork()
        model.nowPlayingPausedAt = nil
    }

    private static func previewArtwork() -> NSImage {
        let size = NSSize(width: 120, height: 120)
        return NSImage(size: size, flipped: false) { rect in
            let accent = Theme.accent(dark: true)
            NSGradient(starting: accent, ending: accent.blended(withFraction: 0.45, of: .black) ?? accent)?
                .draw(in: rect, angle: -60)
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 56, weight: .semibold)) {
                let tinted = NSImage(size: note.size, flipped: false) { r in
                    note.draw(in: r)
                    NSColor.white.withAlphaComponent(0.9).setFill()
                    r.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: NSRect(x: (rect.width - note.size.width) / 2, y: (rect.height - note.size.height) / 2,
                                       width: note.size.width, height: note.size.height))
            }
            return true
        }
    }
}
