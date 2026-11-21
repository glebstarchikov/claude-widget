import XCTest
@testable import ClaudeWidgetCore

final class NowPlayingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_189_119.191445)

    /// The real payload from Gleb's Chrome, 2026-11-20.
    func chrome(playing: Bool? = true, rate: Double? = 1, at received: Date? = nil) -> NowPlaying? {
        NowPlaying(title: "Wish You Were Here", artist: "Pink Floyd", album: "Wish You Were Here",
                   appName: "Google Chrome", bundleId: "com.google.Chrome", pid: 65477, isPlaying: playing,
                   durationMicros: 338_523_718, elapsedMicros: 65_291, timestampMicros: 1_795_189_119_191_445,
                   rate: rate, receivedAt: received ?? t0)
    }

    func testChromePayloadMaps() throws {
        let np = try XCTUnwrap(chrome())
        XCTAssertEqual(np.title, "Wish You Were Here"); XCTAssertEqual(np.appName, "Google Chrome")
        XCTAssertEqual(np.pid, 65477); XCTAssertTrue(np.isPlaying)
        XCTAssertEqual(np.duration!, 338.523718, accuracy: 1e-6)
        XCTAssertEqual(np.elapsed, 0.065291, accuracy: 1e-6)
        XCTAssertEqual(np.timestamp.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1e-3)
        XCTAssertEqual(np.subtitle, "Pink Floyd · Google Chrome")
    }
    func testMissingOrBlankTitleIsNothingPlaying() {
        for title in [nil, "", "   "] as [String?] {
            XCTAssertNil(NowPlaying(title: title, artist: "A", album: nil, appName: "Spotify", bundleId: nil, pid: nil,
                                    isPlaying: true, durationMicros: nil, elapsedMicros: nil, timestampMicros: nil,
                                    rate: nil, receivedAt: t0))
        }
    }
    func testMissingFieldsDefault() throws {
        let np = try XCTUnwrap(NowPlaying(title: "Live", artist: nil, album: nil, appName: "Google Chrome",
                                          bundleId: nil, pid: nil, isPlaying: nil, durationMicros: 0,
                                          elapsedMicros: nil, timestampMicros: nil, rate: nil, receivedAt: t0))
        XCTAssertFalse(np.isPlaying)                 // no flag counts as paused
        XCTAssertNil(np.duration); XCTAssertNil(np.progress(at: t0))
        XCTAssertEqual(np.elapsed, 0); XCTAssertEqual(np.timestamp, t0)
        XCTAssertEqual(np.subtitle, "Google Chrome") // no artist: the app alone
    }
    func testSubtitleSkipsEmptyParts() throws {
        let np = try XCTUnwrap(NowPlaying(title: "T", artist: "", album: nil, appName: nil, bundleId: nil, pid: nil,
                                          isPlaying: true, durationMicros: nil, elapsedMicros: nil,
                                          timestampMicros: nil, rate: nil, receivedAt: t0))
        XCTAssertEqual(np.subtitle, "")
    }
    func testElapsedAdvancesWhilePlayingAndClamps() throws {
        let np = try XCTUnwrap(chrome())
        XCTAssertEqual(np.elapsed(at: t0.addingTimeInterval(10)), 10.065291, accuracy: 1e-3)
        XCTAssertEqual(np.progress(at: t0.addingTimeInterval(10))!, 10.065291 / 338.523718, accuracy: 1e-4)
        XCTAssertEqual(np.elapsed(at: t0.addingTimeInterval(10_000)), 338.523718, accuracy: 1e-6)
        XCTAssertEqual(np.elapsed(at: t0.addingTimeInterval(-60)), 0)
        XCTAssertEqual(try XCTUnwrap(chrome(playing: false)).elapsed(at: t0.addingTimeInterval(10)), 0.065291, accuracy: 1e-6)
    }
    func testMissingRateWhilePlayingIsOne() throws {
        XCTAssertEqual(try XCTUnwrap(chrome(rate: nil)).elapsed(at: t0.addingTimeInterval(5)), 5.065291, accuracy: 1e-3)
    }
    func testToggledPlaybackSnapshotsElapsed() throws {
        let paused = try XCTUnwrap(chrome()).toggledPlayback(at: t0.addingTimeInterval(5))
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.elapsed, 5.065291, accuracy: 1e-3)
        XCTAssertEqual(paused.elapsed(at: t0.addingTimeInterval(50)), 5.065291, accuracy: 1e-3)
        let resumed = paused.toggledPlayback(at: t0.addingTimeInterval(50))
        XCTAssertTrue(resumed.isPlaying)
        XCTAssertEqual(resumed.elapsed(at: t0.addingTimeInterval(52)), 7.065291, accuracy: 1e-3)
    }
    func testToggledPlaybackLiftsOnlyAZeroRateAndOnlyWhenStarting() throws {
        let started = try XCTUnwrap(chrome(playing: false, rate: nil)).toggledPlayback(at: t0)
        XCTAssertTrue(started.isPlaying); XCTAssertEqual(started.rate, 1)    // a start from 0 runs at 1
        let stalled = try XCTUnwrap(chrome(playing: true, rate: 0)).toggledPlayback(at: t0)
        XCTAssertFalse(stalled.isPlaying); XCTAssertEqual(stalled.rate, 0)   // pausing leaves 0 alone
        let fast = try XCTUnwrap(chrome(playing: false, rate: 1.5)).toggledPlayback(at: t0)
        XCTAssertTrue(fast.isPlaying); XCTAssertEqual(fast.rate, 1.5)        // resuming keeps the stored rate
    }
    func testPausedAt() throws {
        let playing = try XCTUnwrap(chrome()), paused = try XCTUnwrap(chrome(playing: false))
        let now = t0.addingTimeInterval(30), earlier = t0.addingTimeInterval(20)
        XCTAssertEqual(NowPlayingRules.pausedAt(previous: playing, next: paused, previousPausedAt: nil, now: now), now)
        XCTAssertEqual(NowPlayingRules.pausedAt(previous: paused, next: paused, previousPausedAt: earlier, now: now), earlier)
        XCTAssertNil(NowPlayingRules.pausedAt(previous: paused, next: playing, previousPausedAt: earlier, now: now))
        XCTAssertNil(NowPlayingRules.pausedAt(previous: nil, next: paused, previousPausedAt: nil, now: now)) // paused at launch
        // A stop (NIL) starts the grace like a pause does; one after a pause keeps that pause's start.
        XCTAssertEqual(NowPlayingRules.pausedAt(previous: playing, next: nil, previousPausedAt: nil, now: now), now)
        XCTAssertEqual(NowPlayingRules.pausedAt(previous: paused, next: nil, previousPausedAt: earlier, now: now), earlier)
        XCTAssertEqual(NowPlayingRules.pausedAt(previous: nil, next: nil, previousPausedAt: earlier, now: now), earlier)
        XCTAssertNil(NowPlayingRules.pausedAt(previous: nil, next: nil, previousPausedAt: nil, now: now)) // NIL at launch
    }

    /// Reports fed through `pausedAt` and `showsStrip` the way the monitor and the strip use them.
    struct Feed {
        var track: NowPlaying?
        var pausedAt: Date?
        mutating func receive(_ next: NowPlaying?, at now: Date) {
            pausedAt = NowPlayingRules.pausedAt(previous: track, next: next, previousPausedAt: pausedAt, now: now)
            track = next
        }
        func shows(at now: Date) -> Bool {
            NowPlayingRules.showsStrip(.init(track: track, pausedAt: pausedAt, now: now, hubOpen: false, pillUp: false,
                                             fullscreen: false, hasNotch: true, enabled: true, notchEnabled: true))
        }
    }
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNilAtLaunchShowsNoStrip() {
        var feed = Feed()
        feed.receive(nil, at: at(0))
        XCTAssertNil(feed.pausedAt)
        XCTAssertFalse(feed.shows(at: at(0))); XCTAssertFalse(feed.shows(at: at(1)))
    }
    func testStopKeepsTheStripForTheGraceThenHides() throws {
        var feed = Feed()
        feed.receive(try XCTUnwrap(chrome()), at: at(0))
        feed.receive(nil, at: at(10))
        XCTAssertTrue(feed.shows(at: at(10))); XCTAssertTrue(feed.shows(at: at(12.9)))
        XCTAssertFalse(feed.shows(at: at(13.0)))
    }
    func testSkipThroughNilNeverHidesTheStrip() throws {
        let next = try XCTUnwrap(NowPlaying(title: "Have a Cigar", artist: "Pink Floyd", album: nil, appName: "Google Chrome",
                                            bundleId: nil, pid: nil, isPlaying: true, durationMicros: 308e6,
                                            elapsedMicros: 0, timestampMicros: nil, rate: 1, receivedAt: at(11)))
        var feed = Feed()
        feed.receive(try XCTUnwrap(chrome()), at: at(0)); XCTAssertTrue(feed.shows(at: at(0)))
        feed.receive(nil, at: at(10)); XCTAssertTrue(feed.shows(at: at(10))); XCTAssertTrue(feed.shows(at: at(10.5)))
        feed.receive(next, at: at(11)); XCTAssertTrue(feed.shows(at: at(11)))
        XCTAssertNil(feed.pausedAt)
        XCTAssertTrue(feed.shows(at: at(14)))   // past the NIL's grace: the new track holds it
    }
    func testNilDoesNotRestartARunningOrSpentGrace() throws {
        let playing = try XCTUnwrap(chrome()), paused = try XCTUnwrap(chrome(playing: false))
        // A NIL inside a pause's grace keeps the pause's deadline.
        var feed = Feed()
        feed.receive(playing, at: at(0)); feed.receive(paused, at: at(10)); feed.receive(nil, at: at(11))
        XCTAssertTrue(feed.shows(at: at(12.9))); XCTAssertFalse(feed.shows(at: at(13.0)))
        // A NIL after a pause whose grace ran out shows nothing.
        feed = Feed()
        feed.receive(playing, at: at(0)); feed.receive(paused, at: at(10)); feed.receive(paused, at: at(20))
        feed.receive(nil, at: at(30))
        XCTAssertFalse(feed.shows(at: at(30)))
        // A second NIL doesn't extend the first one's grace.
        feed = Feed()
        feed.receive(playing, at: at(0)); feed.receive(nil, at: at(10)); feed.receive(nil, at: at(12))
        XCTAssertTrue(feed.shows(at: at(12.9))); XCTAssertFalse(feed.shows(at: at(13.0)))
    }
    func testShowsStrip() throws {
        let base = NowPlayingRules.StripInputs(track: try XCTUnwrap(chrome()), pausedAt: nil, now: t0, hubOpen: false,
                                               pillUp: false, fullscreen: false, hasNotch: true, enabled: true,
                                               notchEnabled: true)
        XCTAssertTrue(NowPlayingRules.showsStrip(base))
        let blockers: [WritableKeyPath<NowPlayingRules.StripInputs, Bool>: Bool] = [
            \.hubOpen: true, \.pillUp: true, \.fullscreen: true, \.hasNotch: false, \.enabled: false, \.notchEnabled: false]
        for (path, value) in blockers { var s = base; s[keyPath: path] = value; XCTAssertFalse(NowPlayingRules.showsStrip(s), "\(path)") }
        var none = base; none.track = nil; XCTAssertFalse(NowPlayingRules.showsStrip(none))
        var paused = base; paused.track = try XCTUnwrap(chrome(playing: false)); paused.pausedAt = t0
        paused.now = t0.addingTimeInterval(2.9); XCTAssertTrue(NowPlayingRules.showsStrip(paused))
        paused.now = t0.addingTimeInterval(3.0); XCTAssertFalse(NowPlayingRules.showsStrip(paused))
        paused.pausedAt = nil; paused.now = t0; XCTAssertFalse(NowPlayingRules.showsStrip(paused))
        // Stopped (no track) inside the grace: shows, and still yields to every blocker.
        var stopped = base; stopped.track = nil; stopped.pausedAt = t0
        stopped.now = t0.addingTimeInterval(2.9); XCTAssertTrue(NowPlayingRules.showsStrip(stopped))
        for (path, value) in blockers { var s = stopped; s[keyPath: path] = value; XCTAssertFalse(NowPlayingRules.showsStrip(s), "stopped \(path)") }
        stopped.now = t0.addingTimeInterval(3.0); XCTAssertFalse(NowPlayingRules.showsStrip(stopped))
    }
    func testRestartBackoffAndGiveUp() {
        let now = t0
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        XCTAssertEqual(NowPlayingRules.restart(exits: [now], now: now), .after(1))
        XCTAssertEqual(NowPlayingRules.restart(exits: [ago(5), now], now: now), .after(10))
        XCTAssertEqual(NowPlayingRules.restart(exits: [ago(20), ago(5), now], now: now), .after(60))
        XCTAssertEqual(NowPlayingRules.restart(exits: [ago(90), ago(20), ago(5), now], now: now), .giveUp)
        XCTAssertEqual(NowPlayingRules.restart(exits: [ago(301), ago(20), ago(5), now], now: now), .after(60))
    }
}
