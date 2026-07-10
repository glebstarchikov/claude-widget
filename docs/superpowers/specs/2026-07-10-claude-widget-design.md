# Claude Widget — design spec

Date: 2026-07-10
Status: approved by Gleb (visual identity, placement, stack, and state colors confirmed in brainstorming session)

## 1. What it is

A native macOS menu bar app where the Claude Code critter (official logo) lives and mirrors all live Claude Code sessions in real time:

- **Legs walk** while Claude is working.
- **Turns Claude orange `#D97757` and pulses** when Claude is blocked waiting for the user (permission request or waiting for input).
- **Sleeps** (dimmed, half-closed eyes) when no sessions are running.
- For interruption-worthy events, a **notch peek panel** slides out from under the MacBook notch, then tucks away.
- Clicking the critter opens a **popover** listing every live session with its state.

Personal tool for Gleb's machine. No API calls, no chat, no telemetry. Reads only local hook events.

## 2. Success criteria

1. Start a Claude Code session (CLI or desktop app) → critter goes from asleep to walking within ~1 s of the first prompt.
2. Claude requests permission or waits for input → critter turns orange and pulses; notch peek appears with the project name.
3. Approve/reply → walking resumes; peek disappears.
4. Turn finishes after a long run → "Finished" peek, auto-hides in 5 s.
5. All sessions closed → critter falls asleep.
6. RAM < 50 MB; zero added latency to Claude sessions (all hooks async).
7. `swift test` passes; `simulate.sh` demos every state without a real session.

## 3. Architecture

```
Claude Code (CLI + desktop app, any number of parallel sessions)
  │  fires hooks (async, never blocks Claude)
  ▼
claude-widget-hook  (tiny compiled Swift CLI, ~10 ms)
  │  writes one JSON file per session (atomic tmp+rename)
  ▼
~/.claude/claude-widget/state/<session_id>.json
  │  watched via DispatchSource directory monitoring (no polling)
  ▼
Claude Widget.app
  ├─ SessionStore        parse files → [Session] → aggregate state
  ├─ StatusItemController critter in the menu bar (draw + animate)
  ├─ NotchPanel          peek panel under the notch
  └─ Popover             session list + settings (SwiftUI)
```

Three deliverables in one SwiftPM package:

| Target | Kind | Contents |
|---|---|---|
| `ClaudeWidgetCore` | library | Event→state mapping, session model, aggregation, staleness GC, critter geometry. Pure logic, no AppKit. Unit-tested. |
| `claude-widget-hook` | executable | Reads hook JSON from stdin + event name as argv[1], writes/deletes state file. Foundation only. |
| `ClaudeWidget` | executable | The app: AppKit status item + SwiftUI popover + notch panel. |

## 4. Hook integration

### 4.1 Events consumed

Registered in `~/.claude/settings.json` (user scope — fires for every project, CLI and desktop app alike). All entries use `"async": true` so Claude never waits.

| Hook event | Matcher | Mapped session state |
|---|---|---|
| `SessionStart` | — | `ready` |
| `UserPromptSubmit` | — | `working` |
| `PreToolUse` | `*` | `working` |
| `PermissionRequest` | `*` | `needsYou` (message: tool name) |
| `Notification` | — | `needsYou` (message from payload) |
| `Stop` | — | `waiting` |
| `SessionEnd` | — | remove state file |

Notes:
- `PreToolUse` (not `PostToolUse`) clears `needsYou` the moment Claude resumes after an approval.
- `Notification` covers both permission prompts and "waiting for your input" idle nudges. `notification_type` is recorded; all types map to `needsYou`.
- Subagent events (`SubagentStart`/`SubagentStop`) are intentionally not consumed; the main-loop events already reflect user-relevant state.
- Gleb's existing Superset hooks coexist: hook arrays are additive and run in parallel.

### 4.2 Hook command

```json
{
  "hooks": [{
    "type": "command",
    "command": "\"$HOME/.claude/claude-widget/bin/claude-widget-hook\" <EventName>",
    "async": true,
    "timeout": 10
  }]
}
```

The binary (compiled Swift, Foundation JSON parsing) reads stdin, extracts `session_id`, `cwd`, `hook_event_name`, `message`, `notification_type`, `tool_name`, and writes the state file atomically (write to `.tmp`, `rename(2)`). No jq/python dependency. If stdin is malformed or `session_id` missing, it exits 0 silently (never disturb Claude).

### 4.3 State file format

`~/.claude/claude-widget/state/<session_id>.json`:

```json
{
  "session_id": "…",
  "state": "working",
  "cwd": "/Users/gleb/some-project",
  "message": "Bash command",
  "working_since": 1783519200.0,
  "updated_at": 1783519262.4
}
```

- `working_since` is set when entering `working` from another state and preserved by every subsequent write in the session (the hook reads the existing file first); it is reset only by `SessionStart`. The app computes the "long task finished" peek rule from it at the `working → waiting` transition.
- Writes are atomic; readers treat any unparseable file as corrupt and delete it.

### 4.4 Setup and teardown (in-app, no install script)

The app self-installs on first run via a button in the popover footer:

- **Install hooks** → ① copy the bundled `claude-widget-hook` binary to `~/.claude/claude-widget/bin/`, ② back up `~/.claude/settings.json` to `settings.json.backup-claude-widget-<timestamp>`, ③ merge the seven hook entries additively (JSONSerialization; idempotent — entries are identified by the `claude-widget-hook` substring and never duplicated).
- **Remove hooks** → reverse the merge (filter out entries containing `claude-widget-hook`), keep the backup.
- Footer shows live status: "Hooks installed ✓" or the Install button.
- App update with a changed hook binary → overwrite the copy in `bin/` on launch.

## 5. State model

### 5.1 Per-session states

`ready → working → (needsYou ⇄ working)* → waiting → …`, terminated by `SessionEnd` or staleness.

### 5.2 Aggregate (icon) state

Priority over all live sessions: **needsYou > working > waiting > ready**; no sessions → **asleep**.

### 5.3 Staleness GC

- A session with `updated_at` older than **4 hours** is dead: file deleted, session dropped.
- GC runs at app launch and every hour. Hook writes happen even while the app is closed; GC bounds the garbage.

## 6. Visual and motion spec

### 6.1 Critter geometry (official logo, viewBox 24×24)

Drawn in code (CoreGraphics rects, even-odd eye cutouts) from the official SVG path in `assets/claudecode.svg`, decomposed:

| Part | Rect (x, y, w, h) |
|---|---|
| Body | 3, 5, 17.998, 12.079 |
| Left nub | 0, 10.95, 3, 3.1 |
| Right nub | 21, 10.949, 3, 3.102 |
| Leg 1 | 4.487, 17.079, 1.513, 2.921 |
| Leg 2 | 7.488, 17.079, 1.512, 2.921 |
| Leg 3 | 15, 17.079, 1.513, 2.921 |
| Leg 4 | 18, 17.079, 1.513, 2.921 |
| Eye left (cutout) | 6, 8.102, 1.488, 2.847 |
| Eye right (cutout) | 16.51, 8.102, 1.49, 2.847 |

Rendered as an 18 pt square status item image (Retina-scaled). Not a template image — tinted programmatically.

### 6.2 States, colors, animation

Colors follow the **menu bar's effective appearance** (observed via the status button), using Gleb's design tokens for "self" states and Claude's brand orange for "Claude asking":

| State | Color (light bar / dark bar) | Opacity | Animation | Reduce Motion fallback |
|---|---|---|---|---|
| asleep | `faint` #6f6e79 / #908f99 | 45 % | none; eyes half-closed (cutouts shrink to bottom 1.05 units) | same (static) |
| ready | `accent` #4b46f5 / #8a86ff | 70 % | blink every 4–7 s (eyes vanish 1 frame, 120 ms) | no blink |
| waiting | rendered identically to `ready` (the popover differentiates) | 70 % | blink | no blink |
| working | `accent` #4b46f5 / #8a86ff | 100 % | walk cycle: legs 1+3 vs 2+4 shorten to 60 % height (top-anchored, feet lift), alternating every 450 ms | static, 100 % opacity (distinguishable from ready by opacity) |
| needsYou | Claude orange #D97757 (both) | 100 % | pulse: opacity 1.0 → 0.55 → 1.0, 1.2 s ease-in-out loop | static orange |

Rationale: indigo = Gleb's accent, and the critter is interactive (clickable), satisfying "accent means interactive". Orange = Claude's own color, used exactly when Claude raises its hand. The only looping animations (walk, pulse) encode live status — information, not decoration — and both honor `NSWorkspace.accessibilityDisplayShouldReduceMotion`.

### 6.3 Notch peek panel

- **Triggers**: aggregate enters `needsYou` (always) · a session transitions `working → waiting` with `now − working_since ≥ 60 s` ("Finished" peek).
- **Dismissal**: `needsYou` peek is sticky until the state resolves, or click. "Finished" peek auto-hides after 5 s. Click also opens the popover (programmatic click on the status item).
- **Placement**: built-in display only (the screen whose `safeAreaInsets.top > 0`); top edge flush under the notch, horizontally centered. No notch visible (lid closed / external only) → no peek; the menu bar critter still signals.
- **Style** (always dark — it extends the black notch): background `elevated` #1c1b1f, 1 px border `border` #2a292e (no top edge), bottom corner radius 14 (`radius-lg`), width ≈ 340 pt. Content: critter (state-colored) + title in `fg` 13 px ("Needs permission" / "Waiting for you" / "Finished") + project folder name and detail in mono `faint` 11 px.
- **Motion**: slide down + fade, 240 ms `expo-out`; reverse to hide. Reduce Motion → fade only, 150 ms.
- **Window**: borderless non-activating `NSPanel`, level above status bar, joins all Spaces, ignores no mouse events, never steals focus.

### 6.4 Popover (click the critter)

SwiftUI in an `NSPopover`, width 300 pt, Gleb's tokens, light/dark follows system:

- Section label `SESSIONS` — mono uppercase 11 px, the view's single mono label.
- One **list row** per session (lists over cards): project folder name in `fg` 14 px; status dot (working `accent`, needsYou #D97757, waiting `success`, ready `faint`); elapsed time since `updated_at` in mono `faint` 12 px. Hairline separators. Hover shifts background to `elevated`.
- Empty state, one sentence in `secondary`: "No sessions. The critter sleeps."
- Footer: toggles for **Launch at login** (`SMAppService`) and **Notch alerts**; hooks status/install button (§4.4); **Quit**. Toggle state persists in `UserDefaults`.
- Fonts: Geist Sans / Geist Mono if installed, else SF Pro / SF Mono. Not bundled in v1.

## 7. Project structure

```
claude-widget/
├── Package.swift
├── assets/claudecode.svg            # official path (source of truth for geometry)
├── assets/claudecode-color.svg
├── Sources/
│   ├── ClaudeWidgetCore/            # models, mapping, aggregation, GC, geometry
│   ├── ClaudeWidgetHook/            # main.swift for claude-widget-hook
│   └── ClaudeWidget/                # app: status item, panel, popover, setup
├── Tests/ClaudeWidgetCoreTests/
├── scripts/
│   ├── bundle.sh                    # swift build -c release → Claude Widget.app → ad-hoc codesign → /Applications
│   └── simulate.sh                  # replays a fake session lifecycle into the state dir
└── docs/superpowers/specs/
```

- App bundle: `LSUIElement = true` (no Dock icon), bundle id `com.glebstarchikov.claude-widget`, min macOS 14.
- App icon: critter rendered in indigo, generated at build time by `bundle.sh` (render PNG set → `iconutil`).
- No sandbox (personal distribution; needs `~/.claude` access).

## 8. Error handling and edge cases

| Case | Behavior |
|---|---|
| Malformed/partial state file | Impossible via atomic rename; any unparseable file is deleted on read |
| Session killed without `SessionEnd` (crash, closed terminal) | 4 h staleness GC; until then shows last state |
| `/clear` (new session id, old file lingers) | old file GC'd; new session tracked immediately |
| Hooks fire while app closed | cheap file writes; GC on next launch |
| `settings.json` merge | backup first, additive, idempotent; existing (Superset) hooks untouched |
| Hook binary missing (moved app) | hook command exits silently; popover shows Install button again |
| No notch anywhere | peeks skipped; menu bar states carry all information |
| Menu bar appearance change (wallpaper/theme) | colors re-resolved via appearance observation |
| Reduce Motion enabled | all loops replaced per §6.2/§6.3 |

## 9. Testing

- **Unit (ClaudeWidgetCore)**: hook JSON → session state (each event type, `working_since` preservation, malformed input); aggregate priority for all combinations; staleness GC boundaries; long-task peek rule (≥ 60 s).
- **Integration**: `simulate.sh` writes state files replaying: start → prompt → tools → permission request → approve → stop(long) → end. Used to eyeball every animation and peek without spending tokens.
- **Manual gate**: one real Claude Code session; verify success criteria 1–5.
- CI-style gate locally: `swift build && swift test` green before any "done" claim.

## 10. Out of scope (v2 candidates)

- Click-to-focus the terminal/app owning a session
- Fallback top-center pill peek on external displays
- Sounds on needs-you
- Token/cost display per session, session titles from `session_title`
- Notarized public distribution — **note: the critter and the Claude Code logo are Anthropic trademarks; fine for a personal tool, revisit identity before ever shipping publicly**

## 11. Key constants (single source in code)

| Constant | Value |
|---|---|
| Walk frame duration | 450 ms |
| Pulse period | 1.2 s |
| Blink interval | random 4–7 s |
| Finished-peek threshold | 60 s working |
| Finished-peek auto-hide | 5 s |
| Staleness GC | 4 h, checked hourly |
| Peek slide | 240 ms expo-out |
| State dir | `~/.claude/claude-widget/state/` |
| Hook binary | `~/.claude/claude-widget/bin/claude-widget-hook` |
