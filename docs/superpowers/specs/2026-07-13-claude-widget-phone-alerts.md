# Claude Widget — Phone Alerts (ntfy)

**Date:** 2026-07-13
**Status:** Approved design, pending implementation plan
**Depends on:** the shipped Claude Widget app (see `2026-07-10-claude-widget-design.md`)

## Goal

Let the widget follow you off the desk: when a Claude Code session **needs you**
(permission / input) or a **long task finishes**, buzz your iPhone — so you can
step away and still know when to come back.

This is *alerts only*. Not an iOS app, widget, or Live Activity — no Apple
Developer account, no Xcode iOS target, no server.

## Decisions (locked during brainstorming)

| Decision | Choice | Why |
|---|---|---|
| Scope | Push alerts only | ~90% of the value for ~1% of the effort; no dev account |
| Channel | **ntfy** | Free, open-source, no account, self-hostable for true privacy |
| Fired from | **The menu bar app** (not the hook) | Reuses `Aggregator.peekEvents`; keeps all network I/O out of Claude's hook path |
| Alert detail | **Project + reason** | Only the folder name leaves the Mac — no commands, paths, or prompts |
| Onboarding | Copyable **topic** + "Send test" button | ntfy's QR / `ntfy://` subscribe is Android-only per its docs; copy-paste + a test buzz is the reliable iOS path |

## Architecture

The feature splits along the existing Core/App seam: pure formatting logic
(testable, no side effects) in `ClaudeWidgetCore`, the network call and UI in the
`ClaudeWidget` app.

### Integration point

`SessionMonitor.onChange` already hands the app `peeks: [PeekEvent]` and the app
loops over them to drive the notch (`AppDelegate.swift`). The **only** change to
the hot path is one line in that existing loop:

```swift
for peek in peeks {
    pushNotifier.send(peek)          // ← new
    switch peek {
    case .needsYou(let s): notch.showNeedsYou(s)
    case .finished(let s, let d): notch.showFinished(s, duration: d)
    }
}
```

Transition detection is already edge-triggered by `Aggregator.peekEvents`
(`.needsYou` only when a session *enters* needs-you; `.finished` only when a
task that ran ≥ `finishedPeekThreshold` (60s) stops). No new de-duplication or
rate-limiting is needed — reuse it as-is.

### Component 1 — `PushMessage` (Core, pure, unit-tested)

Maps a `PeekEvent` to a channel-agnostic payload. This is where the
"project + reason" privacy rule is enforced *by construction*.

```swift
public enum PushPriority: String { case min, low, `default`, high, urgent }

public struct PushPayload: Equatable {
    public let title: String
    public let body: String
    public let priority: PushPriority
    public let tags: [String]        // ntfy emoji shortcodes, e.g. ["eyes"]
}

public enum PushMessage {
    public static func from(_ peek: PeekEvent) -> PushPayload
}
```

Mapping:

| Event | title | body | priority | tags |
|---|---|---|---|---|
| `.needsYou(session)` | `Claude needs you` | `<projectName>` | `urgent` | `eyes` 👀 |
| `.finished(session, d)` | `Finished` | `<projectName> · <duration>` | `high` | `white_check_mark` ✅ |

- The **category is carried by the title** (`Claude needs you` vs `Finished`), so the
  `body` needs only `session.projectName` (the cwd's last path component) — plus the
  duration for `.finished`. It never includes `session.message`, `session.tool`,
  commands, or paths, so the payload can't leak beyond the folder name regardless of
  what Claude was doing.
- `<duration>` uses a shared duration formatter (see Refactor below), e.g. `4m 20s`.

### Component 2 — `PushNotifier` (App)

Reads config and performs a **fire-and-forget** POST. Best-effort by design:
any failure is swallowed and must never perturb the app or Claude.

```swift
struct PushNotifier {
    func send(_ peek: PeekEvent)     // no-op when disabled
}
```

ntfy publish API (verified against ntfy docs):

```
POST https://ntfy.sh/<topic>
Title: <payload.title>
Priority: <payload.priority.rawValue>
Tags: <payload.tags joined by ",">

<payload.body>                 ← request body, UTF-8
```

- `URLSession.shared` `dataTask`, no completion handling beyond ignoring errors.
- Server + topic come from config; the path uses the generated topic verbatim
  (topic is `[a-z0-9]`, URL-safe).
- Access-controlled topics (an `Authorization: Bearer tk_…` header) are a future
  extension, not v1.

### Config (`UserDefaults`, alongside the existing toggles)

| Key | Type | Default | Notes |
|---|---|---|---|
| `pushEnabled` | Bool | `false` | Master switch |
| `pushTopic` | String | *generated* | `claude-<8 random [a-z0-9]>`, created on first enable |
| `pushServer` | String | `https://ntfy.sh` | Change this one field to self-host |

Registered in `AppDelegate` next to `notchAlertsEnabled` / `notchProactiveEnabled`.
Exposed as `@Published` properties on `AppModel` with `didSet` persistence, matching
the existing pattern.

### UI — popover section

A new block under the existing toggles in `PopoverView`:

- **Toggle "Notify my phone"** (`pushEnabled`). On first enable, generate `pushTopic`.
- When on, reveal:
  - The topic string, prominent and **copyable** (click-to-copy), plus the server if
    non-default.
  - A **"Send test"** button → `PushNotifier` posts a `Test alert · it works` message,
    so onboarding ends in a real buzz you can confirm.
- A one-line hint: "Install the ntfy app → tap +, paste this topic → Send test."

## Refactor (in-scope cleanup)

`NotchPanelController.format(_ duration:)` already formats `4m 20s` / `45s`. The
finished-alert body needs the same string, so hoist that helper into Core (e.g.
`public enum DurationFormat { static func short(_:) -> String }`) and have both the
notch and `PushMessage` use it — one implementation, no duplicate.

## Privacy & security

- **Topic is the only secret.** Public `ntfy.sh` is not end-to-end encrypted;
  anyone who knows the topic can read it. We generate a long random topic so it's
  unguessable, and document that self-hosting (or an ntfy account with a reserved
  topic) is the path to real access control.
- **Minimal payload.** Only the project folder name + an event category ever leave
  the machine. Enforced in `PushMessage`, so it can't regress silently.
- **Self-host friendly.** `pushServer` is one field; point it at your own ntfy.
- **Best-effort, non-blocking.** Fire-and-forget; a failed alert is invisible to
  the app and to Claude.
- **Off by default.** No traffic leaves the machine until the user flips the toggle.

## Testing

- **Unit (Core, `PushMessageTests`):**
  - `.needsYou` → title/body/priority/tags exactly as specified.
  - `.finished` → duration rendered correctly (`0s`, `45s`, `4m 20s`, `1m 0s`).
  - Body contains the project name and **not** `session.message` / `session.tool`
    (guards the privacy invariant against future edits).
- **Manual:** the "Send test" button; and `scripts/simulate.sh` already produces
  real needs-you / finished transitions with the app running.

## Out of scope (v1, YAGNI)

- Headless / hook-fired alerts (works only while the menu bar app runs — which it
  does whenever your Mac is on).
- A detail-level setting (fixed to project + reason).
- iOS app, home-screen widget, or Live Activity.
- ntfy auth tokens / reserved topics.
- QR / `ntfy://` deep-link subscribe (Android-only in ntfy's docs; revisit only if the
  iOS app is confirmed to have an in-app QR scanner).
- Delivery guarantees, retries, or queued/offline alerts.
- Other channels (Pushover/Telegram) — the `PushMessage`/`PushNotifier` split keeps
  the door open, but not built now.

## Files

**New**
- `Sources/ClaudeWidgetCore/PushMessage.swift`
- `Tests/ClaudeWidgetCoreTests/PushMessageTests.swift`
- `Sources/ClaudeWidget/PushNotifier.swift`

**Changed**
- `Sources/ClaudeWidgetCore/*` — hoisted duration formatter (+ update `NotchPanel` to use it)
- `Sources/ClaudeWidget/AppDelegate.swift` — register defaults, instantiate `PushNotifier`, call `send(peek)`
- `Sources/ClaudeWidget/AppModel.swift` — `pushEnabled` / `pushTopic` / `pushServer`, topic generation, `sendTest()`
- `Sources/ClaudeWidget/PopoverView.swift` — "Notify my phone" section (toggle, copyable topic, test)
- `README.md` — document phone alerts + ntfy onboarding
