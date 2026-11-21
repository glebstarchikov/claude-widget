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
    func testPausedAt() throws {
        let playing = try XCTUnwrap(chrome()), paused = try XCTUnwrap(chrome(playing: false))
        let now = t0.addingTimeInterval(30), earlier = t0.addingTimeInterval(20)
        XCTAssertEqual(NowPlayingRules.pausedAt(previous: playing, next: paused, previousPausedAt: nil, now: now), now)
        XCTAssertEqual(NowPlayingRules.pausedAt(previous: paused, next: paused, previousPausedAt: earlier, now: now), earlier)
        XCTAssertNil(NowPlayingRules.pausedAt(previous: paused, next: playing, previousPausedAt: earlier, now: now))
        XCTAssertNil(NowPlayingRules.pausedAt(previous: playing, next: nil, previousPausedAt: nil, now: now))
        XCTAssertNil(NowPlayingRules.pausedAt(previous: nil, next: paused, previousPausedAt: nil, now: now)) // paused at launch
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
