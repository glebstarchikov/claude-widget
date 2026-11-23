# Now playing — design

**Status:** approved by Gleb, 2026-11-21 ("Approved"). Project 2 of the notch hub (`2026-11-17-notch-hub-design.md`), built on themes (`2026-11-19-themes-design.md`). Labels: [Gleb …] is his decision; [my call] is mine, open to correction.

## 1. Intent

Gleb wants the hub to show "what's playing (Spotify or anything else)" [Gleb, 2026-11-17], and he wants it "in the eyebrow": a glance at the notch tells you what's on without opening anything [Gleb chose B, 2026-11-19]. Music is a quick Mac tool next to the agents, which are why this app exists, so the music views have to feel like part of the Mac and never compete with Claude.

## 2. Goals, non-goals, anti-goals

- **Goals:** show the track macOS is playing from any app (Spotify, Apple Music, a browser tab, podcasts); back, play/pause and next from the hub; a small view around the closed notch while music plays; nothing at all when nothing plays.
- **Non-goals:** seeking, volume, queue, lyrics; choosing between several players; real audio levels; a music view beside the notch on displays without one (the hub card covers them); Spotify-only features; a second source for when the adapter breaks.
- **Anti-goals:** music hiding or delaying a Claude alert; anything moving beside the notch when nothing plays or during a fullscreen video; error messages in the hub when the adapter breaks; any permission prompt (Automation, Screen Recording, microphone, Accessibility) to read music.

## 3. Decisions

### 3.1 Source: mediaremote-adapter, vendored [Gleb chose option 1, 2026-11-19]

**How it works.** macOS 15.4 stopped answering MediaRemote (the private framework behind Control Center's Now Playing) for ordinary apps. Apple's own `/usr/bin/perl` (signed `com.apple.perl`) is still answered. The adapter's dylib is loaded into perl, which streams one JSON line per change to the app and takes commands (play, pause, next…) on the same process. Upstream: `ungive/mediaremote-adapter`; we use the SwiftPM fork `ejbills/mediaremote-adapter`, BSD 3-Clause.

**Verified on Gleb's Mac, 2026-11-20** (macOS 26.4.1, 25E253), through the fork's own Swift code:
- A real Chrome/YouTube track arrived with title, artist, album, app name and bundle id, PID, playing flag, duration, elapsed time with its timestamp, playback rate, and JPEG artwork (150 × 150 from Chrome; 300 × 300 from a test publisher).
- The dylib was only linker-signed (ad hoc) and still got answers.
- With nothing playing, the adapter answers `NIL`; the system log shows MediaRemote's error code 35, "Could not find the specified now playing client". This is the same answer a silently broken adapter would give.

**Vendored, not fetched.** The fork's package uses `unsafeFlags(["-fobjc-arc"])`, which SwiftPM refuses in a remote dependency. Copy the fork at commit `7d5b6cc` into `Vendor/MediaRemoteAdapter/` with its LICENSE, note the upstream URL and commit in a short `Vendor/MediaRemoteAdapter/VENDORED.md`, and depend on it by local path. Nothing is fetched at build time. The README credits it.

**Three patches in the vendored copy** (each needed for the installed app, not for `swift run`); VENDORED.md lists them:
1. **Library path.** The fork finds its dylib with `Bundle(for: MediaController.self).executablePath`, which assumes Xcode's framework layout. Resolve it from the loaded image instead (`dladdr` on one of the dylib's own exported symbols). perl rejects relative paths, so it must be absolute.
2. **Script path.** The fork finds `run.pl` through `Bundle.module`. SwiftPM's generated lookup tries the `.app`'s root folder (where codesign forbids files), then the absolute `.build` path on the machine that built it, and otherwise calls `fatalError`. Look for `run.pl` in the app's `Contents/Resources` first and use `Bundle.module` only as the fallback for `swift run`.
3. **Listener exits.** The fork reports a dead listener only if it had delivered at least one payload. Report every exit, so the app can tell "broken" from "silent" (§3.6).

**Packaging.** `scripts/bundle.sh` copies `libMediaRemoteAdapter.dylib` to where the executable finds it (the executable's rpath is `@loader_path`, so `Contents/MacOS` works with no rpath change) and `run.pl` to `Contents/Resources`, before the existing ad hoc `codesign --force --deep`.

### 3.2 What counts as "playing" [my call, from the check]

- `NIL` means nothing to show. So does a payload whose title is missing or empty. The card and the notch view are hidden; no error.
- A track that is paused but still listed (Spotify keeps it listed for a long time) keeps its hub card, with a play button. The notch view leaves after the grace period (§3.4).
- One source at a time: whichever app macOS chose for Now Playing, the same one Control Center shows.
- A payload with no playing flag counts as paused.
- The listener reports the current track as soon as it starts (seen in the check), so music already playing at launch shows at once.

### 3.3 Hub card [Gleb approved in the A/B mockup, 2026-11-19]

- **Place:** its own glass module between Limits and Agents, present only while there's a track.
- **Content:** artwork at 44 pt with rounded corners; the title on one line, truncated; "Artist · App" below it (the artist is left out when missing; the app is the reported name, e.g. "Spotify", "Google Chrome"); a thin progress bar in the theme accent; back, play/pause and next buttons on the right.
- **Artwork** is never drawn larger than 44 pt, because browsers send about 150 px. Missing artwork: a rounded square with the `music.note` symbol in the secondary color [my call].
- **Progress:** elapsed = reported elapsed + (now − timestamp) × rate, clamped to the duration. It ticks once a second, only while the hub is open. No duration (a live stream): no bar [my call].
- **Buttons** call toggle play/pause, previous and next. They respond to the first click (the hub panel never becomes key). The play/pause icon flips at once and the next payload corrects it if needed [my call].
- **Clicking the artwork or title** brings the playing app to the front, by PID, else by bundle id [my call]. For a browser that is the browser, not the tab.
- **No seeking:** the bar only shows progress [my call; seeking is a non-goal].

### 3.4 Around the closed notch [Gleb chose B, 2026-11-19]

While a track plays and the hub is closed, the black notch widens on both sides: the artwork on the left, four level bars in the theme color on the right.

- **Shape:** one black shape flush with the top of the screen and as tall as the menu bar, spanning the notch plus a flank on each side, with bottom corners rounded like the hardware notch. Each flank is about as wide as the menu bar is tall (≈ 32–38 pt; the mockup went from 190 to 250 pt in all). The artwork is a little smaller than the menu bar height, with rounded corners.
- **Level bars** are decorative, not audio levels: real levels would need a permission (anti-goal). They move while playing and rest low and still when paused. With Reduce Motion they stay still at uneven heights. Their color is the theme accent for dark surfaces (`Theme.accent(dark: true)`), because the notch is always black.
- **Shows** when a track starts playing, growing out of the notch with the hub's spring (a fade with Reduce Motion).
- **Leaves** 3 s after the track pauses or stops, so a skip or a quick pause doesn't flicker [my call on 3 s; the mockup said "a few seconds"]. If those 3 s run out while the hub is open, the strip stays away when the hub closes.
- **Hidden while:**
  - the hub is open (the card is in the hub); it returns when the hub closes;
  - any pill is up (needs you, a permission request, finished) [Gleb: alerts win];
  - the front app is fullscreen on the notched screen [the hub's rule: in fullscreen only alerts get through]. Re-checked when the space or front app changes, not polled.
- **No notch** (external display, lid closed): nothing appears; the card in the hub, opened from the critter, still works [Gleb, mockup].
- **Pointer:** the widened notch counts as the notch. Dwelling on it opens the hub (the same dwell, under the same "Open on hover" setting), and clicking it opens the hub [my call]. So the hover area, the click area and the areas that keep an open hub open all include the strip while it shows.
- **The cost Gleb accepted:** while music plays, the strip covers about 35 pt of menu bar on each side of the notch. A menu title or status item sitting right next to the notch is hidden until the music stops, or for good with the setting off (§3.5).

### 3.5 Settings [my call]

A new **Music** section:
- **Show what's playing** (on by default). Off: no perl process, no card, no notch view.
- **Around the closed notch** (on by default), disabled while the first is off.
- When the adapter can't run (§3.6), a secondary line under the first toggle: "Not available on this version of macOS."

UserDefaults keys: `nowPlayingEnabled`, `nowPlayingNotchEnabled`.

### 3.6 When the adapter breaks [my call; changes what I said on 2026-11-19]

On 2026-11-19 I said the card would read "Music unavailable". The check showed that a common way to break, empty answers, can't be told apart from silence. So the hub never shows an error: no track, no card. What can be detected is the perl listener dying (the dylib won't load, a crash). The app restarts it with backoff (1 s, 10 s, 60 s). Exits the app caused don't count: the fork restarts perl on purpose after every 100 updates, and the setting stops it. After three failed starts within 5 minutes it stops trying and marks music unavailable, which shows only in Settings. It tries again at the next launch, or when the setting is switched off and on.

### 3.7 Previewing without music [my call]

An argument-domain flag, `-nowPlayingPreview YES`, feeds a fixed fake track (title, artist, app, artwork, playing) instead of the adapter. It allows live checks and screenshots without playing music and without starting perl, and never reaches users.

## 4. Approaches (laid out 2026-11-19)

1. **The adapter through the SwiftPM fork** (chosen). Any app, live pushed updates, full controls. Risk: a macOS update can close the perl route; then music silently disappears (§3.6).
2. **Spotify only, through its AppleScript.** Official, but Spotify only, a one-time Automation prompt, polling rather than live updates. Apple Music's scripting is broken on macOS 26 (Apple developer forums threads 801357 and 798267), so it can't be the "other apps" half.
3. **The adapter with Spotify scripting as a fallback.** Survives a broken adapter for Spotify only, at the cost of two code paths for one card. Deferred until the adapter actually breaks.

Not considered further: calling MediaRemote from the app itself (blocked since macOS 15.4).

## 5. Shape of the code (what the builder shouldn't have to guess)

- **Core (`ClaudeWidgetCore`, unit-tested, no AppKit, no adapter):** a `NowPlaying` value (title, artist, album, app name, bundle id, PID, playing flag, duration, elapsed, timestamp, rate, artwork bytes and MIME type), plus pure rules:
  - adapter-shaped fields → `NowPlaying?` (nil for `NIL` or an empty title);
  - elapsed at a given time, and progress;
  - the "Artist · App" line;
  - whether the notch view shows, from: track, when it paused, now, hub open, pill up, fullscreen, notch present, both settings. Includes the 3 s grace.
- **App:** a `NowPlayingMonitor`, shaped like `UsageMonitor`. It owns the adapter's `MediaController`, maps payloads into Core, publishes `nowPlaying` on `HubModel`, applies §3.6, starts and stops with the setting, and sends the commands. Track details never go into logs; state changes only [my call].
- **Hub:** a `NowPlayingModule` in `HubView` between Limits and Agents. `HubLayout.maxHubHeight` grows by the card's height, so the panel fits Limits, the card and a full Agents list.
- **Notch view:** it lives in the menu bar band, above where the hub's content hangs. The hub panel's transparent margin reaches only about 16 pt into that band, so the strip needs its own panel or a taller hub panel; either way it uses the hub panel's window recipe (`.screenSaver` level, `.canJoinAllSpaces`, never key, mouse events only over what's visible) and draws on the notched screen only.

## 6. Constraints

- macOS 26, Swift 5 mode, SwiftPM. One vendored dependency, nothing fetched at build time. CI (`macos-latest`, macOS 26, Swift 6.3.3) must build it. Local unsafe flags are allowed, but confirm on CI.
- No new permissions, and nothing about what's playing leaves the Mac.
- Tests never start perl or touch MediaRemote, like the existing rule for the Keychain, the socket and the network. Core rules are tested with fixed payloads, including the real Chrome payload shape from the check.
- Energy: the listener is pushed, not polled. The progress tick runs only while the hub is open, and the bars move only while the strip is visible.
- Live check of the bundled app, one copy only, `-limitsEnabled NO`:
  - with the preview flag;
  - with a real track: the card, the controls, the strip appearing and leaving, alerts taking over;
  - with nothing playing: no card, no strip.
- README: a "Now playing" section (how it reads music, that a macOS update could switch it off, the BSD credit) and the Settings line.

## 7. Left to the builder

- Exact flank width, artwork size and corner radii, matched against a real-size screenshot of the notch.
- Whether the notch view is its own panel or part of the hub panel (within §5's recipe).
- The bars' animation.
- Button symbols and hit sizes.
- How fullscreen changes are observed (within §3.4: on change, not polled).
- Backoff details within §3.6.
