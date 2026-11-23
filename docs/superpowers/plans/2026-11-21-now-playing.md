# Now Playing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show what macOS is playing in the hub (a card with back, play/pause and next) and, while music plays, as artwork and level bars around the closed notch.

**Architecture:** A vendored copy of `ejbills/mediaremote-adapter` streams Now Playing through Apple's `/usr/bin/perl`. A `NowPlayingMonitor` maps its payloads into a Core `NowPlaying` value on `HubModel`. Pure rules in Core decide what shows (track or nothing, progress, the 3 s pause grace, the strip's visibility, restart backoff). Two views read the model: a `NowPlayingModule` card in the hub, and a `NotchStripController` panel in the menu bar band beside the notch.

**Tech Stack:** Swift 5 mode (tools 5.10), SwiftPM, AppKit + SwiftUI (Liquid Glass), XCTest; vendored ObjC/Swift adapter (BSD-3).

**Spec:** `docs/superpowers/specs/2026-11-21-now-playing-design.md` (approved 2026-11-21). Read it before any task.

## Global Constraints

- macOS 26 (`.macOS("26.0")`), Swift 5 language mode, SwiftPM only. The adapter is vendored at `ejbills/mediaremote-adapter` commit `7d5b6cc` under `Vendor/MediaRemoteAdapter/` with its LICENSE; nothing is fetched at build time.
- CI (`.github/workflows/ci.yml`, which reaches this branch with main's merge; `macos-latest` is macOS 26 with Swift 6.3.3) must build the vendored package. Confirm on the PR's first CI run.
- `swift build` adds no warnings in our targets (`ClaudeWidget`, `ClaudeWidgetCore`, `claude-widget-hook`). Note, don't fix, any warnings inside the vendored package.
- Tests never start perl, never touch MediaRemote, the Keychain, the approval socket, `~/.claude/claude-widget`, or the network.
- No new permissions (Automation, Screen Recording, microphone, Accessibility). Nothing about what's playing leaves the Mac. Logs carry state changes only, never a title, artist or app name.
- Settings copy, exact: section **Music**; toggles **Show what's playing** and **Around the closed notch**; status line **Not available on this version of macOS.**
- UserDefaults: `nowPlayingEnabled` (default `true`), `nowPlayingNotchEnabled` (default `true`), both registered in `AppDelegate`. `nowPlayingPreview` is argument-domain only, with no registered default.
- Values: pause grace **3 s**; restart delays **1 s, 10 s, 60 s**; failure window **300 s**; card artwork **44 pt**; card progress ticks every **1 s** and only while the hub is open; **4** level bars; each strip flank as wide as the menu bar is tall.
- Order in the hub: Limits, then the music card, then Agents.
- Live checks of a bundled build:
  - Exactly one copy runs, started with `-limitsEnabled NO`. Check with `pgrep -fl "Claude Widget.app/Contents/MacOS"`.
  - Quit it with `pkill -TERM -f "build/Claude Widget.app/Contents/MacOS/Claude Widget"`, then confirm with `pgrep` that it has exited.
  - Launch with `"build/Claude Widget.app/Contents/MacOS/Claude Widget" <flags> &` from the worktree, sandbox off.
  - Capture windows by ID: find them with `CGWindowListCopyWindowInfo` (owner "Claude Widget"), then `screencapture -x -o -l<id>`.
  - Use `/usr/bin/log`: in zsh, bare `log` is a builtin.

## Review Focus

1. **Nothing playing, at launch or forever** (also how a silently broken adapter looks): no card, no strip, no error anywhere. Pinned by Task 2's nil-title tests and Task 3's "nothing playing" launch check.
2. **Sparse metadata** (a browser video with no artist, no artwork, or a live stream with no duration): the subtitle shows the app alone, artwork shows the placeholder, and there's no progress bar. Pinned by Task 2's subtitle and progress tests and Task 4's `-nowPlayingPreview sparse` capture.
3. **An alert while music plays:** the strip gives way to the pill and comes back after. Pinned by Task 2's `showsStrip` pill test and Task 5's `simulate.sh approve` check.
4. **A fullscreen app while music plays:** no strip; it returns when fullscreen ends. Pinned by Task 2's fullscreen test and Task 5's check, which compares a fullscreen space with a normal one.
5. **Process hygiene:**
   - The setting off means no perl process. Quitting kills perl.
   - A crashed app leaves no perl behind: the adapter's listener checks its parent every 5 s and exits.
   - A listener that keeps dying ends in the Settings line, not in a restart loop.
   - Pinned by Task 3's `pgrep -fl run.pl` checks and its kill test.

## Rulings (where this plan narrows the spec)

- **Artwork stays in the app layer** as the adapter's decoded `NSImage` (`HubModel.nowPlayingArtwork`), not as bytes in Core. Core has no AppKit, and decoding twice is waste. If wrong: one extra field in Core.
- **Give-up threshold:** music is marked unavailable on the **4th** unexpected listener exit within 300 s, which means three failed restarts (spec §3.6: "three failed starts"). If wrong: one constant.
- **The preview flag takes a value:** `-nowPlayingPreview YES` shows a full fake track; `-nowPlayingPreview sparse` shows one with no artist, no artwork and no duration (Review Focus 2). If wrong: drop the sparse variant.
- **A developer flag** `--now-playing-check` (DevTools) prints the adapter's resolved library and script paths and one read of the current track, then exits. It proves patches 1 and 2 in the bundled app before any UI exists. If wrong: delete ~20 lines.
- **Missing playback rate** while playing counts as 1.0 (the fork's own math uses 0, which would freeze the bar). If wrong: one default.

---

### Task 1: Vendor the adapter, patch it, package it

**Files:**
- Create: `Vendor/MediaRemoteAdapter/` (the fork's `Package.swift`, `LICENSE`, `Sources/` at `7d5b6cc`; not its `.git` or README), `Vendor/MediaRemoteAdapter/VENDORED.md`
- Modify: `Vendor/MediaRemoteAdapter/Sources/MediaRemoteAdapter/MediaController.swift` (the three patches)
- Modify: `Package.swift`, `scripts/bundle.sh`, `Sources/ClaudeWidget/DevTools.swift`

**Interfaces:**
- Produces: the module `MediaRemoteAdapter` (`MediaController`, `TrackInfo`) linked into the `ClaudeWidget` target. `MediaController` gains `public var libraryPath: String?` and `public var perlScriptPath: String?`. `onListenerTerminated` fires for every listener exit or failed start the app didn't cause.

- [ ] **Step 1: Copy the fork.** `git clone https://github.com/ejbills/mediaremote-adapter "$TMPDIR/mra" && git -C "$TMPDIR/mra" checkout 7d5b6cc`, then copy `Package.swift`, `LICENSE` and `Sources/` into `Vendor/MediaRemoteAdapter/`. Network and the worktree write need the sandbox off.

- [ ] **Step 2: Patch 1, library path.** Replace the private `libraryPath` (it uses `Bundle(for:)`) with a public one that resolves the loaded image of one of the dylib's own C symbols. Add `import CIMediaRemote` to the file:

```swift
public var libraryPath: String? {
    var info = Dl_info()
    let symbol: @convention(c) () -> Void = bootstrap
    guard dladdr(unsafeBitCast(symbol, to: UnsafeRawPointer.self), &info) != 0,
          let name = info.dli_fname else { return nil }
    // perl refuses relative paths; dyld may report one for a relatively launched binary.
    return URL(fileURLWithPath: String(cString: name)).standardizedFileURL.resolvingSymlinksInPath().path
}
```

- [ ] **Step 3: Patch 2, script path.** Make `perlScriptPath` public. Return `Bundle.main.path(forResource: "run", ofType: "pl")` first, and fall back to `Bundle.module.path(forResource: "run", ofType: "pl")` only if that is nil. In an installed app, `Bundle.module` must never be evaluated: its generated accessor calls `fatalError` when its bundle is missing.

- [ ] **Step 4: Patch 3, listener exits.**
  - In `startListeningInternal`, the termination handler reports (and clears state) only when the exiting process is still the current one: `guard let self, self.listeningProcess === process else { return }`. Then nil out `listeningProcess` and `listeningInputPipe`, and call `onListenerTerminated?()`. Drop the old `eventCount != 0` condition.
  - `stopListening` and `restartListeningProcess` already nil `listeningProcess` before terminating, so their exits go unreported.
  - When the listener can't start (nil script or library path, or `run()` throws), call `onListenerTerminated?()` on the main queue.

- [ ] **Step 5: Write `VENDORED.md`:** the upstream URL, commit `7d5b6cc`, the date, the three patches in one line each, and "update only on purpose; re-run the now-playing live check after any update".

- [ ] **Step 6: Wire the package.** In `Package.swift`, add `dependencies: [.package(path: "Vendor/MediaRemoteAdapter")]`, and add `.product(name: "MediaRemoteAdapter", package: "MediaRemoteAdapter")` to the `ClaudeWidget` executable target's dependencies. No other target links it.

- [ ] **Step 7: Package it.** In `scripts/bundle.sh`, right after the two existing `cp .build/release/…` lines, copy `.build/release/libMediaRemoteAdapter.dylib` to `"$APP/Contents/MacOS/"` (the executable's rpath is `@loader_path`). Then copy `Vendor/MediaRemoteAdapter/Sources/MediaRemoteAdapter/Resources/run.pl` to `"$APP/Contents/Resources/"`. Both happen before `codesign`.

- [ ] **Step 8: Developer check flag.** In `DevTools.run`, handle `--now-playing-check`:
  - Print `library: <path> (found|missing)` and `script: <path> (found|missing)`.
  - Call `getTrackInfo` once, waiting at most 5 s on `RunLoop.main`, and print `track: <title> — <applicationName>` or `track: none`.
  - Return `true`, so the app exits. It's a dev tool on demand, so printing the title here is fine.

- [ ] **Step 9: Verify.** Run each command and confirm the expected result:
  - `swift build 2>&1 | grep -E "warning|error"` shows nothing from our targets.
  - `swift test` reports `Executed 297 tests, with 0 failures`.
  - `scripts/bundle.sh` (no `--install`) runs, and `codesign --verify --deep --strict "build/Claude Widget.app"` exits 0.
  - `"build/Claude Widget.app/Contents/MacOS/Claude Widget" --now-playing-check` (sandbox off) reports a library path inside `build/Claude Widget.app/Contents/MacOS/` (found) and a script path inside `Contents/Resources/` (found), then a `track:` line.
  - `pgrep -fl run.pl` shows nothing afterwards.

- [ ] **Step 10: Commit.** `git add Vendor Package.swift scripts/bundle.sh Sources/ClaudeWidget/DevTools.swift && git commit -m "feat: vendor mediaremote-adapter (patched for the .app) and bundle it"`

### Task 2: Core: the `NowPlaying` value and its rules

**Files:**
- Create: `Sources/ClaudeWidgetCore/NowPlaying.swift`
- Test: `Tests/ClaudeWidgetCoreTests/NowPlayingTests.swift`

**Interfaces:**
- Produces:
  - `public struct NowPlaying: Equatable, Sendable` with `title: String`, `artist: String?`, `album: String?`, `appName: String?`, `bundleId: String?`, `pid: Int32?`, `isPlaying: Bool`, `duration: TimeInterval?`, `elapsed: TimeInterval`, `timestamp: Date`, `rate: Double`.
  - Its initializer, `public init?(title: String?, artist: String?, album: String?, appName: String?, bundleId: String?, pid: Int32?, isPlaying: Bool?, durationMicros: Double?, elapsedMicros: Double?, timestampMicros: Double?, rate: Double?, receivedAt: Date)`.
  - `public func elapsed(at now: Date) -> TimeInterval`, `public func progress(at now: Date) -> Double?`, `public var subtitle: String`, and `public func toggledPlayback(at now: Date) -> NowPlaying`.
  - `public enum NowPlayingRules`, holding:
    - the constants `pauseGrace = 3`, `restartDelays: [TimeInterval] = [1, 10, 60]` and `failureWindow = 300`;
    - `static func pausedAt(previous: NowPlaying?, next: NowPlaying?, previousPausedAt: Date?, now: Date) -> Date?`;
    - `struct StripInputs: Equatable { var track: NowPlaying?; var pausedAt: Date?; var now: Date; var hubOpen, pillUp, fullscreen, hasNotch, enabled, notchEnabled: Bool }` with a memberwise `public init`;
    - `static func showsStrip(_ inputs: StripInputs) -> Bool`;
    - `enum Restart: Equatable { case after(TimeInterval), giveUp }` and `static func restart(exits: [Date], now: Date) -> Restart`.

Rules the tests pin (the spec's §3.2, §3.3, §3.4, §3.6):
- **The initializer:**
  - nil for a nil or whitespace-only title;
  - `isPlaying ?? false`;
  - `duration` is nil unless `durationMicros > 0`;
  - `elapsed = (elapsedMicros ?? 0) / 1e6`;
  - `timestamp` comes from `timestampMicros`, else `receivedAt`;
  - `rate = rate ?? (playing ? 1 : 0)`.
- **`elapsed(at:)`:** while playing, `elapsed + (now − timestamp) × rate`; otherwise `elapsed`. Clamped to `0…duration`, or `≥ 0` when there's no duration.
- **`progress`:** nil without a duration.
- **`subtitle`:** the non-empty values of artist and appName, joined by `" · "`.
- **`toggledPlayback(at:)`:** flips `isPlaying`, sets `elapsed = elapsed(at: now)` and `timestamp = now`, and keeps the rate at 1 when it starts playing from a stored 0.
- **`pausedAt`:**
  - nil if `next` is nil or playing;
  - `now` if `previous` was playing and `next` isn't;
  - otherwise `previousPausedAt`.
- **`showsStrip`:** true only if all of these hold:
  - `enabled`, `notchEnabled` and `hasNotch`;
  - not `hubOpen`, not `pillUp`, not `fullscreen`;
  - there is a track;
  - it is playing, or `now < pausedAt + pauseGrace`.
- **`restart`:** count the exits no older than `failureWindow` (that count is `n`, including the newest). If `n` is 1–3, return `.after(restartDelays[n − 1])`; if it's 4 or more, `.giveUp`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run them to confirm they fail.** Run `swift test --filter NowPlayingTests`; expected: compile errors, because `NowPlaying` and `NowPlayingRules` don't exist yet.
- [ ] **Step 3: Implement** `Sources/ClaudeWidgetCore/NowPlaying.swift` to the rules above. Foundation only.
- [ ] **Step 4: Run all tests.** `swift test` should report `Executed 307 tests, with 0 failures` (297 + 10).
- [ ] **Step 5: Commit.** `git add Sources/ClaudeWidgetCore/NowPlaying.swift Tests/ClaudeWidgetCoreTests/NowPlayingTests.swift && git commit -m "feat(core): NowPlaying value, strip visibility and restart rules"`

### Task 3: The monitor, settings and the preview flag

**Files:**
- Create: `Sources/ClaudeWidget/Hub/NowPlayingMonitor.swift`
- Modify: `Sources/ClaudeWidget/Hub/HubModel.swift`, `Sources/ClaudeWidget/AppModel.swift`, `Sources/ClaudeWidget/AppDelegate.swift`, `Sources/ClaudeWidget/SettingsView.swift`

**Interfaces:**
- Consumes: `MediaController` (Task 1), `NowPlaying`, `NowPlayingRules` (Task 2).
- Produces, on `HubModel` (add `import AppKit`):
  - `@Published var nowPlaying: NowPlaying?`, `@Published var nowPlayingArtwork: NSImage?`, `@Published var nowPlayingPausedAt: Date?`;
  - `var nowPlayingCommand: (NowPlayingCommand) -> Void = { _ in }`, `var openNowPlayingApp: () -> Void = {}`;
  - `enum NowPlayingCommand { case togglePlayPause, previous, next }`.
- Produces, on `AppModel`: `@Published var nowPlayingEnabled: Bool`, `@Published var nowPlayingNotchEnabled: Bool` (both persisted like `limitsEnabled`), and `@Published var nowPlayingUnavailable = false` (not persisted).
- Produces: `@MainActor final class NowPlayingMonitor` with `init(model: HubModel)`, `var onUnavailableChange: (Bool) -> Void`, `func start()`, `func stop()`, `func send(_ command: NowPlayingCommand)`, `func openApp()`.

- [ ] **Step 1: The monitor's payload path, `start()`.** It creates the `MediaController`, sets the callbacks, and calls `startListening()`. On each payload:
  - Build `NowPlaying(…, receivedAt: Date())` from `TrackInfo.Payload` (`PID` is `pid_t`).
  - Compute `nowPlayingPausedAt` with `NowPlayingRules.pausedAt` from the previous `model.nowPlaying`.
  - Publish the track. Publish `payload.artwork` as the artwork, or nil when there's no track.
  - Decoding errors are logged as a count only and change nothing.

- [ ] **Step 2: Exits and backoff.** In `onListenerTerminated`, record the exit time and apply `NowPlayingRules.restart(exits:now:)`:
  - `.after(d)`: start listening again after `d` seconds, through a cancellable `Task`.
  - `.giveUp`: clear the published track, call `onUnavailableChange(true)`, and stop.
  - `stop()` cancels any pending restart, calls `stopListening()`, clears the three published values and the exit list, and calls `onUnavailableChange(false)`.
  - Log category: `extension Logger { static let nowPlaying = Logger(subsystem: "com.glebstarchikov.claude-widget", category: "nowPlaying") }`. Log start, stop, exit, restart and give-up, with no track data.

- [ ] **Step 3: Commands and opening the app.**
  - `send(.togglePlayPause)` publishes `model.nowPlaying?.toggledPlayback(at: now)`, updates `nowPlayingPausedAt` through `pausedAt(…)`, then calls `togglePlayPause()`. `.previous` and `.next` call `previousTrack()` and `nextTrack()`.
  - `openApp()` activates `NSRunningApplication(processIdentifier:)` for the track's PID, else the first running app with its bundle id.

- [ ] **Step 4: The preview.** `UserDefaults.standard.string(forKey: "nowPlayingPreview")` decides it. When the value is `"YES"` or `"sparse"`, `start()` never creates a `MediaController`. It publishes a fixed track instead:
  - Full: title "Preview Track", artist "Claude Widget", app "Music", duration 245 s, elapsed 61 s, playing. Artwork is a generated 120 × 120 image: a gradient in `Theme.accent(dark: true)` with the `music.note` symbol.
  - `sparse`: no artist, no artwork, no duration, app "Google Chrome".
  - In preview, toggle flips locally, and previous, next and `openApp` do nothing.

- [ ] **Step 5: Settings and wiring.**
  - `AppDelegate`: register `nowPlayingEnabled: true` and `nowPlayingNotchEnabled: true`, then create the monitor after `hub.start()`.
  - Set `hubModel.nowPlayingCommand` and `hubModel.openNowPlayingApp` to call it, and set `onUnavailableChange` to update `model.nowPlayingUnavailable`.
  - Sink `model.$nowPlayingEnabled` to start or stop the monitor, like `limitsToggle`.
  - In `applicationWillTerminate`, call `stop()` on the monitor.
  - In `SettingsView`, add a `Section("Music")` after "Notch" with `Toggle("Show what's playing", isOn: $model.nowPlayingEnabled)` and, when `nowPlayingUnavailable`, `Text("Not available on this version of macOS.")` in the callout/secondary style.
  - Under it goes `Toggle("Around the closed notch", isOn: $model.nowPlayingNotchEnabled).disabled(!model.nowPlayingEnabled)`.

- [ ] **Step 6: Verify.** Build, run `swift test` (307 pass), then `scripts/bundle.sh`. Then one bundled copy at a time, with the sandbox off, each check followed by quitting the copy:
  - `--show-settings -limitsEnabled NO`: capture the Settings window and see the Music section. `pgrep -fl run.pl` shows exactly one `run.pl … loop`.
  - `-limitsEnabled NO -nowPlayingEnabled NO`: `pgrep -fl run.pl` shows nothing.
  - `-limitsEnabled NO -nowPlayingPreview YES`: `pgrep -fl run.pl` shows nothing.
  - **Kill test:** `-limitsEnabled NO --show-settings`. Run `pkill -f "run.pl.*loop"`, wait for the restart (`pgrep`), and repeat until the 4th kill (about 75 s in all). Afterwards no perl restarts, and a fresh Settings capture shows "Not available on this version of macOS."
  - **Hygiene:** quitting leaves no `run.pl`. `kill -9` on the app leaves no `run.pl` after 6 s.

- [ ] **Step 7: Commit.** `git add Sources/ClaudeWidget && git commit -m "feat: now-playing monitor, Music settings and preview flag"`

### Task 4: The hub card

**Files:**
- Create: `Sources/ClaudeWidget/Hub/NowPlayingModule.swift`
- Modify: `Sources/ClaudeWidget/Hub/HubView.swift`

**Interfaces:**
- Consumes: `HubModel.nowPlaying`, `.nowPlayingArtwork`, `.nowPlayingCommand`, `.openNowPlayingApp` (Task 3).
- Produces:
  - `struct NowPlayingModule: View` with `init(track: NowPlaying, artwork: NSImage?, command: @escaping (NowPlayingCommand) -> Void, openApp: @escaping () -> Void)`;
  - `HubLayout.nowPlayingHeight: CGFloat = 48`;
  - `maxHubHeight = limitsHeight + nowPlayingHeight + 2 * moduleSpacing + maxListHeight + 6 * modulePadding`.

- [ ] **Step 1: Build the card** to spec §3.3:
  - **Layout:** `TimelineView(.periodic(from: .now, by: 1))`, which only runs while the hub is open because the card lives in the expanded hub. Inside it, an `HStack` holds:
    - the artwork, 44 × 44, corner radius 8; the placeholder is a rounded square with `music.note` in `.secondary`. The artwork, together with the title and subtitle block, is one plain `Button` calling `openApp`.
    - a `VStack` with the title (13 pt semibold, one line, truncated tail), the subtitle (11 pt, `.secondary`, one line), and, only when `progress(at:)` isn't nil, a 3 pt capsule bar filled in `Theme.accent(dark:)` for the current color scheme;
    - `Spacer`, then borderless buttons `backward.fill`, `play.fill` / `pause.fill` and `forward.fill`, with accessibility labels "Previous", "Play"/"Pause" and "Next".
  - **Padding:** horizontal `SessionRow.horizontalPadding`; frame height `HubLayout.nowPlayingHeight`.

- [ ] **Step 2: Put it in the hub.** In `HubView`, between Limits and Agents, `if let track = model.nowPlaying { NowPlayingModule(…) .padding(HubLayout.modulePadding).glassEffect(.regular, in: RoundedRectangle(cornerRadius: HubLayout.cornerRadius, style: .continuous)) }`. Add `.animation(animation, value: model.nowPlaying == nil)` beside the existing animations. Update `HubLayout.maxHubHeight` as above.

- [ ] **Step 3: Verify.** Build, run `swift test` (307 pass), then `scripts/bundle.sh`. Capture the hub window for each launch below. Each shows Limits off, the card above the Agents module, and nothing clipped at the panel's bottom:
  - `--show-hub -limitsEnabled NO -nowPlayingPreview YES`: the full preview card.
  - `--show-hub -limitsEnabled NO -nowPlayingPreview sparse`: placeholder artwork, "Google Chrome" alone, no bar.
  - `--show-hub -limitsEnabled NO -nowPlayingEnabled NO`: no card.

- [ ] **Step 4: Commit.** `git add Sources/ClaudeWidget/Hub && git commit -m "feat: now-playing card in the hub"`

### Task 5: The strip around the closed notch, and the README

**Files:**
- Create: `Sources/ClaudeWidget/Hub/NotchStrip.swift` (`NotchStripController` and its SwiftUI view)
- Modify: `Sources/ClaudeWidget/Hub/HubController.swift`, `Sources/ClaudeWidget/AppDelegate.swift`, `README.md`

**Interfaces:**
- Consumes: `NowPlayingRules.showsStrip`, `.pauseGrace` (Task 2); `HubModel`'s now-playing fields (Task 3); `NotchMetrics`; `Theme.accent(dark: true)`.
- Produces, on `HubController`:
  - `func setStripFrame(_ frame: NSRect?)`. While it's non-nil, the notch dwell zone is `notch.hoverZone.union(frame)`, and `notchPlacement` adds the frame to `keepZones`, so a hub opened from a flank stays open.
  - `func openFromNotch()`: `expand(at: notchPlacement(notch), byHover: false)` when a notch exists.
  - `activeAppIsFullscreen(on:)` changes from `private` to `internal`.
- Produces: `@MainActor final class NotchStripController` with `init(model: HubModel, appModel: AppModel, hub: HubController)` and `func start()`.

- [ ] **Step 1: The panel.**
  - Use the hub panel's recipe: borderless and non-activating, never key, `.screenSaver` level, `[.canJoinAllSpaces]`, clear, no shadow, first-click hosting view.
  - Its frame sits on `NotchMetrics().screen`: width `notchWidth + 2 * topInset`, height `topInset`, centered, top flush with the screen's top.
  - `ignoresMouseEvents = !visible`.
  - Re-measure on `didChangeScreenParametersNotification`; with no notched screen, the strip stays hidden.

- [ ] **Step 2: The view, spec §3.4.**
  - **The shape:** a black `UnevenRoundedRectangle` with bottom corner radius about 10. While visible its width animates from `notchWidth` to the full width, using the hub's spring; with Reduce Motion it fades.
  - **The left flank:** the artwork, a square `topInset − 14` pt (at least 16) with corner radius 5, falling back to the `music.note` placeholder in white at 60 %.
  - **The right flank:** four bars, 3 pt wide and 2 pt apart, at most `topInset − 16` pt tall, in `Theme.accent(dark: true)`. While playing (and not with Reduce Motion) they move, from `TimelineView(.animation)` with per-bar phases. When paused they rest low. With Reduce Motion they sit still at uneven heights.
  - **A click** on the strip calls `hub.openFromNotch()`.

- [ ] **Step 3: When it shows.**
  - Recompute `NowPlayingRules.showsStrip` from: `model.nowPlaying`, `nowPlayingPausedAt`, `expanded` and `pill != nil`; the two `AppModel` settings; `HubController.activeAppIsFullscreen(on:)`, which is re-read on `NSWorkspace.activeSpaceDidChangeNotification` and `didActivateApplicationNotification` (workspace notification center, not polled); and `hasNotch`.
  - When the result depends on the grace, schedule one recompute at `pausedAt + pauseGrace`.
  - On every visibility change, call `hub.setStripFrame(visible ? panel.frame : nil)`.
  - In `AppDelegate`, create and start the controller after the monitor.

- [ ] **Step 4: README.**
  - Add a "Now playing" section: what shows where; that it reads macOS's Now Playing through Apple's perl (the method from mediaremote-adapter, BSD-3, vendored with credit); that a macOS update could switch it off; and that nothing leaves the Mac.
  - Add "Music" to the Settings line.
  - In "Develop locally", add `-nowPlayingPreview YES|sparse` and `--now-playing-check`.

- [ ] **Step 5: Verify.** Build, run `swift test` (307 pass), then `scripts/bundle.sh`. All captures are screen regions over the notch (`screencapture -x -R`), taken on a desktop that isn't full screen:
  - `-limitsEnabled NO -nowPlayingPreview YES`: the strip shows artwork, a black band and moving bars, at 2x, light and dark menu bar.
  - The same copy with `scripts/simulate.sh approve` started after launch: the strip is gone while the pill is up and back after the request ends (about 30 s).
  - `-nowPlayingNotchEnabled NO -nowPlayingPreview YES`: no strip.
  - With an app full screen on the notched display: no strip; it returns on leaving fullscreen.
  - Hovering and clicking a flank are Gleb's hands-on checks: the hub opens and stays open while the pointer rests on the flank. A cursor warp doesn't fire the app's mouse-move monitors, and synthetic events need permissions this setup lacks.

- [ ] **Step 6: Commit.** `git add Sources/ClaudeWidget README.md && git commit -m "feat: now-playing strip around the closed notch; README"`

---

## After the last task

Live check with real music, one bundled copy, `-limitsEnabled NO`, on Gleb's Mac:
- A track playing in Chrome or Spotify: the card shows title, "Artist · App", artwork and a moving bar. The strip appears.
- Gleb pauses from the source app: the strip leaves 3 s later and the card keeps a play button.
- Nothing playing: no card, no strip, nothing in Settings.
- Gleb's hands-on:
  - click back, play/pause and next;
  - click the artwork to bring the app forward;
  - hover on a flank, and click one, to open the hub.
