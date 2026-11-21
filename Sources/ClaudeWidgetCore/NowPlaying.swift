import Foundation

/// What macOS reports as playing right now, in the shape the app wants rather than
/// the adapter's. Artwork is not here: Core has no AppKit, so the app layer keeps
/// the decoded image beside this value.
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var appName: String?
    public var bundleId: String?
    public var pid: Int32?
    public var isPlaying: Bool
    /// nil for a live stream or anything else with no length.
    public var duration: TimeInterval?
    /// Seconds into the track as of `timestamp`.
    public var elapsed: TimeInterval
    /// When `elapsed` was true.
    public var timestamp: Date
    public var rate: Double

    /// Maps the adapter's fields (times in microseconds). nil when there is no
    /// title: "nothing playing" is the same to us whether the adapter says so,
    /// is broken, or never started.
    public init?(title: String?, artist: String?, album: String?, appName: String?, bundleId: String?,
                 pid: Int32?, isPlaying: Bool?, durationMicros: Double?, elapsedMicros: Double?,
                 timestampMicros: Double?, rate: Double?, receivedAt: Date) {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let playing = isPlaying ?? false
        self.title = title
        self.artist = artist
        self.album = album
        self.appName = appName
        self.bundleId = bundleId
        self.pid = pid
        self.isPlaying = playing
        self.duration = (durationMicros ?? 0) > 0 ? durationMicros! / 1e6 : nil
        self.elapsed = (elapsedMicros ?? 0) / 1e6
        self.timestamp = timestampMicros.map { Date(timeIntervalSince1970: $0 / 1e6) } ?? receivedAt
        // A missing rate while playing counts as 1: the bar must keep moving.
        self.rate = rate ?? (playing ? 1 : 0)
    }

    /// Where the track is at `now`: extrapolated while playing, held while paused.
    public func elapsed(at now: Date) -> TimeInterval {
        let value = isPlaying ? elapsed + now.timeIntervalSince(timestamp) * rate : elapsed
        let floored = max(0, value)
        return duration.map { min($0, floored) } ?? floored
    }

    /// 0...1, or nil when there is no length to measure against.
    public func progress(at now: Date) -> Double? {
        guard let duration else { return nil }
        return elapsed(at: now) / duration
    }

    /// Artist and app, whichever exist, for the line under the title.
    public var subtitle: String {
        [artist, appName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The state we expect after a play/pause click, so the UI answers before the
    /// adapter's next report. A start from a stored rate of 0 runs at 1.
    public func toggledPlayback(at now: Date) -> NowPlaying {
        var next = self
        next.elapsed = elapsed(at: now)
        next.timestamp = now
        next.isPlaying.toggle()
        if next.isPlaying && next.rate == 0 { next.rate = 1 }
        return next
    }
}

/// The now-playing decisions, apart from AppKit and the adapter so each can be tested.
public enum NowPlayingRules {
    /// A pause keeps the strip this long, so a skip or a brief gap doesn't make it flicker.
    public static let pauseGrace: TimeInterval = 3
    /// Waits before restarting the listener after its 1st, 2nd and 3rd unexpected exit.
    public static let restartDelays: [TimeInterval] = [1, 10, 60]
    /// Only exits this recent count towards giving up.
    public static let failureWindow: TimeInterval = 300

    /// When the current pause began. Only a play-to-pause change starts it: a track
    /// already paused at launch never shows the strip.
    public static func pausedAt(previous: NowPlaying?, next: NowPlaying?, previousPausedAt: Date?, now: Date) -> Date? {
        guard let next, !next.isPlaying else { return nil }
        if previous?.isPlaying == true { return now }
        return previousPausedAt
    }

    public struct StripInputs: Equatable {
        public var track: NowPlaying?
        public var pausedAt: Date?
        public var now: Date
        public var hubOpen: Bool
        public var pillUp: Bool
        public var fullscreen: Bool
        public var hasNotch: Bool
        public var enabled: Bool
        public var notchEnabled: Bool

        public init(track: NowPlaying?, pausedAt: Date?, now: Date, hubOpen: Bool, pillUp: Bool,
                    fullscreen: Bool, hasNotch: Bool, enabled: Bool, notchEnabled: Bool) {
            self.track = track
            self.pausedAt = pausedAt
            self.now = now
            self.hubOpen = hubOpen
            self.pillUp = pillUp
            self.fullscreen = fullscreen
            self.hasNotch = hasNotch
            self.enabled = enabled
            self.notchEnabled = notchEnabled
        }
    }

    /// Whether the strip beside the closed notch shows: it yields to the hub, the
    /// approval pill and fullscreen, and outlives a pause only for `pauseGrace`.
    public static func showsStrip(_ inputs: StripInputs) -> Bool {
        guard inputs.enabled, inputs.notchEnabled, inputs.hasNotch,
              !inputs.hubOpen, !inputs.pillUp, !inputs.fullscreen,
              let track = inputs.track else { return false }
        if track.isPlaying { return true }
        guard let pausedAt = inputs.pausedAt else { return false }
        return inputs.now < pausedAt.addingTimeInterval(pauseGrace)
    }

    public enum Restart: Equatable {
        case after(TimeInterval)
        case giveUp
    }

    /// What to do after the listener exits unexpectedly. `exits` includes the exit
    /// just seen. The 4th within `failureWindow` is three failed restarts: give up.
    public static func restart(exits: [Date], now: Date) -> Restart {
        let recent = exits.filter { now.timeIntervalSince($0) <= failureWindow }.count
        guard recent <= restartDelays.count else { return .giveUp }
        return .after(restartDelays[max(recent, 1) - 1])
    }
}
