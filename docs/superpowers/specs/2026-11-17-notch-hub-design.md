# Notch Hub — design (project 1 of 4)

Date: 2026-11-17
Status: implemented on `feat/notch-hub` (2026-11-17); end-to-end checks pending
Supersedes the popover and notch-peek parts of `2026-07-10-claude-widget-design.md`. The hook → state-file pipeline, critter, session model and phone alerts from that spec stay as they are unless this document says otherwise.

Tags used below: **[Gleb]** = decided by Gleb in the brainstorming session. **[proposed]** = Claude's call, not yet objected to; change it if it's wrong. Everything untagged is a consequence of the tagged decisions or is left to the builder (see §13).

---

## 1. Intent

Turn the notch into a **hub**: a native-feeling macOS 26 panel that drops out of the notch and shows what Gleb's Claude agents are doing, how much Claude usage is left, and lets him answer Claude's permission prompts without hunting for the right window. Later projects add quick Mac tools (now playing, file conversion, a reading list) to the same hub.

Why: today the notch only *tells* Gleb that something happened (a one-line peek); to act he has to open the popover or find the terminal. He wants one place, at the top of the screen, that is both glanceable and useful, and that feels like part of macOS rather than a widget bolted on. He likes NotchNook's feel. **Behaviour matters as much as looks** [Gleb] — the hub must never get in the way.

The menu bar critter stays [Gleb]. Both surfaces (notch hub + critter) are needed; the old popover goes away [proposed — Gleb said "eyebrow and the thing on the right"].

## 2. Roadmap (this doc covers project 1 only)

| # | Project | Notes for later |
|---|---|---|
| **1** | **Hub shell + agents + Claude limits + answer-from-notch** | this document |
| 2 | Now playing (Spotify or anything) | system now-playing info needs the community `mediaremote-adapter` workaround since macOS 15.4 (works on 26, may break on any update); Spotify-only via AppleScript is the stable fallback |
| 3 | Convert files | drag a file to the notch → pick a format; prefer macOS built-ins (images/video/PDF) — verify formats then |
| 4 | Read list | trending topics as links; click opens in **Chrome**, where Gleb summarizes with his own plugin [Gleb]. The hub never summarizes. |
| later | Optional providers | Claude first [Gleb]. Codex limits/sessions and Vercel deploy status are *optional connectables* later, not built now [Gleb]. Gleb's Codex is a Business plan whose session logs show no 5h/weekly windows, only credits. |

Project 1 must lay out the hub so projects 2–4 slot in without re-layout (see §5), but builds none of them.

## 3. Goals, non-goals, anti-goals

**Goals**
1. A Liquid Glass hub under the notch that opens on hover and feels native and pleasant [Gleb].
2. Live agents (sessions + subagents) in the hub, with today's information (state, model, tool, elapsed, context, click-to-focus).
3. Claude usage limits (5-hour and weekly %) with reset time.
4. Answer Claude's permission prompts (Allow / Deny) from the notch [Gleb].
5. Works without a notch (external display / lid closed) by clicking the critter.

**Non-goals (project 1)**
- Now playing, file conversion, read list, Codex, Vercel (later projects).
- "Always allow" / permission rules from the notch — Allow and Deny only, once [proposed].
- Answering `AskUserQuestion`, plan approval (`ExitPlanMode`) or "waiting for your input" from the notch — not supported by hooks in a usable way.
- Keyboard shortcuts / keyboard control of the hub.
- Notarized public distribution.

**Anti-goals — failure even if everything "works"**
- The hub opens when Gleb didn't mean it (brushing the top of the screen, reaching for a menu or a browser tab).
- The hub takes keyboard focus or interrupts typing in another app.
- Claude gets slower, or hangs, because of the widget — especially when the app isn't running.
- Anything gets approved without Gleb clicking Allow.
- The widget writes Claude Code's own Keychain entry (it holds Claude Code's MCP sign-ins too), or ever loses a renewed sign-in silently. (Renewing the sign-in itself is accepted — see §7.)
- Solid custom colors painted over glass (it looks off; glass is the surface now).

## 4. Approaches considered

**Where the hub lives.** (a) Evolve this app — chosen; the only sensible option. (b) Fork boring.notch (open-source notch app with music player) — rejected: large codebase with its own design to strip out, and this app's hook pipeline is clean. (c) A separate hub app next to the critter app — rejected: two installs, two processes, no gain.

**Look.** Liquid Glass modules under a black notch vs. a NotchNook-style black slab growing out of the notch. A throwaway spike of both was built and screenshotted. **Glass** [Gleb]. The notch itself stays black (it reads as hardware, like the iPhone's Dynamic Island).

**Claude limits source.** (A) Claude Code's official status line (`rate_limits.five_hour/seven_day` in the statusline JSON) — documented, but only refreshes while a terminal session renders its status line, and the docs don't say it runs in the desktop app, where Gleb mostly works. (B) The usage feed that usage menu-bar apps (CodexBar, claude-usage-bar, …) use: poll Anthropic's OAuth usage endpoint with Claude Code's own sign-in from the Keychain — works everywhere, even with no session running; undocumented, may break. **B** [Gleb].

**Hook ↔ app channel for answering prompts.** (A) Request/response files, like the rest of the app. (B) A local Unix socket. **B** [Gleb]. Its practical upside: when the app isn't running, `connect()` fails instantly, so the hook falls through with no added delay and leaves no stale files.

## 5. Look

**Theme** [proposed, accepted in conversation]:
- Surfaces are system Liquid Glass (`glassEffect(.regular, in:)` inside a `GlassEffectContainer`). No custom background or border colors.
- System font (SF) everywhere; `monospacedDigit()` for timers and percentages. Geist/Geist Mono and the uppercase mono labels are retired from the hub.
- Text uses system hierarchical styles (primary/secondary) so it stays readable in light, dark, and over busy wallpapers.
- Color only means state: indigo (`#4B46F5` light / `#8A86FF` dark) = Claude working / interactive; Claude orange `#D97757` = Claude needs you. **Do not** use the user's system accent color (an orange accent would collide with "needs you"). Limit rings: indigo; system red at ≥ 90% [proposed — keeps orange reserved for "Claude is asking"].
- The notch stays black. The menu bar critter keeps its current rendering.

**Hub layout (project 1).** Fixed width 660 pt, height fits content, ~8 pt below the menu bar, centered under the notch. A vertical stack of glass modules (24 pt continuous corner radius, 10 pt gaps):

```
              ▁▁▁▁ notch ▁▁▁▁
 ╭──────────────────────────────────────────────╮
 │ (42%)(61%)  Claude · 5h resets in 2h 10m  ⚙ │   Limits module (compact)
 ╰──────────────────────────────────────────────╯
 ╭──────────────────────────────────────────────╮
 │ 🦀 claude-widget  Opus  Edit Notch…   4m    │   Agents module
 │ 🦀 api-server   Allow Bash: npm test?       │
 │                          [Deny] [Allow]     │
 │    └ Explore · Grep "rate_limits"           │   subagent
 ╰──────────────────────────────────────────────╯
```

Projects 2–4 will add a now-playing module beside Limits and turn Agents into the first of several tabs (Agents · Read · Convert). In project 1 there is **no tab bar** and **no empty placeholder** for unbuilt features.

**Agents module.** One row per session (as today: animated state-colored critter, project name, model badge, current tool, elapsed, context usage, nested subagents; click → focus the owning app). The owning app's small icon (Terminal, Cursor, Claude desktop…) replaces a text "source" chip [proposed]. A session with a pending permission request shows the request text and **Deny / Allow** inline. Empty state: sleeping critter + "No sessions. The critter sleeps." Rows beyond ~6 scroll.

**Pill (alerts).** A small glass capsule under the notch (~380 × 48 pt), not the whole hub:
- Needs-you with a live request: pulsing orange critter · "api-server · Bash: npm test" · **Deny** · **Allow** (Allow = prominent glass tinted indigo).
- Needs-you without a live request (e.g. a Notification event, or app not answering): same pill, no buttons; click → focus the session's app.
- Finished (worked ≥ 60 s then stopped): "api-server finished · 4m", auto-hides after 5 s.
- Hovering the pill expands it into the full hub (morph with the glass container).

## 6. Behaviour [Gleb approved the list; numbers are proposed starting points from the spike]

- **Open:** mouse dwells over the notch area (notch width + 16 pt each side, menu-bar height) for **150 ms** → hub opens with a spring (response ≈ 0.45 s, damping ≈ 0.75) and one soft haptic tap. Brushing through faster than that never opens it.
- **Close:** mouse outside the hub's frame (+30 pt margin) for **300 ms** → closes. Never while an Allow/Deny is mid-click or while the pointer is over a pill.
- **Focus:** the hub is a non-activating panel and **never becomes key**; typing elsewhere is never interrupted. (No text fields in project 1.)
- **Alerts** arrive as the pill (§5), honoring the existing "Show proactively" toggle.
- **Fullscreen:** while another app is fullscreen on the notched display, hover does not open the hub; only pills appear.
- **No notch** (external display / lid closed): clicking the critter opens the same hub as a glass panel anchored under the critter. Pills in that case appear under the critter too.
- **Several displays, lid open** [proposed]: pills go to the screen the pointer is on — under the notch on the built-in display, otherwise a glass pill top-center under that screen's menu bar. Hover-to-open exists only at the notch; the critter click works on any screen.
- **Critter clicks:** left click → hub; right click → small menu (Settings…, Quit).
- **Motion:** Reduce Motion → fades (≈150 ms), no springs, no scale.
- **Memory:** reopens with the same scroll/expanded state as last time (tabs arrive in project 2+).

## 7. Claude limits (usage feed) [Gleb chose the feed]

**Revised 2026-11-17 after live measurement (see §15).** The desktop app keeps its sign-in to itself, and terminal Claude's saved sign-in only stays fresh while terminal Claude is used. A `claude setup-token` year-long token is rejected by the usage feed (403). So **the widget renews a sign-in itself** [Gleb: "lets do the limits", accepting the renewal route] and **keeps its own copy** [Gleb: "Yes, own copy"].

**The sign-in the widget uses:**
- **Its own Keychain entry**, service `Claude Widget-usage-credentials`, account = the macOS user name, value = small JSON `{"accessToken","refreshToken","expiresAt"}` (≈ 0.5 KB). Written and read only through `/usr/bin/security` (write: `security -i` with `add-generic-password -U … -X <hex>` on **stdin**, so no secret ever appears in a process's arguments; items made by the `security` tool don't re-prompt after rebuilds of the ad-hoc-signed app). Every write is verified: check the exit status and stderr, then read back and compare. A failed write must never be silent.
- **Adoption:** when the widget has no entry of its own, it reads Claude Code's `Claude Code-credentials` entry **read-only** (`claudeAiOauth.accessToken` / `refreshToken` / `expiresAt`) and saves a copy as its own. It **never writes Claude Code's entry**: that entry is ~33 KB (it also holds Claude Code's MCP sign-ins), `security -i` can't save values that large, and writing it back could wipe an MCP sign-in Claude Code saved in between.
- **Renewal:** when the access token is within 5 min of expiry, or the usage feed answers 401/403, renew once: `POST https://platform.claude.com/v1/oauth/token`, JSON `{"grant_type":"refresh_token","refresh_token":…,"client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`, `User-Agent: claude-widget/1.0 (macOS)` (the endpoint rejects generic agents). Save the new access token, the **rotated** refresh token and the new expiry to the widget's own entry **before** using them, then retry the usage call once. Only one renewal in flight at a time.
- **Known consequence** [Gleb accepted]: renewing rotates the refresh token, so terminal Claude's saved copy stops working after the widget's first renewal; terminal Claude then asks for `/login` the next time it renews.
- **When renewal fails** (invalid/revoked refresh token): re-read Claude Code's entry; if its refresh token differs from the one the widget last adopted (Gleb ran `/login` again), adopt it and retry; otherwise show **"Sign-in expired · run /login in terminal Claude"** and retry every 30 min.
- Tokens live in memory only as long as a request needs them. Never log, print, or send them anywhere but `api.anthropic.com` (usage) and `platform.claude.com` (renewal).

**Request:** `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20` and the same User-Agent. The response's **`limits` array** is the primary source — one window per entry: `{kind, group, percent, severity, resets_at, scope{model{display_name}}, is_active}` (live on 2026-11-17: weekly_all 78 % "warning"; weekly_scoped Fable 100 % "critical", active). Fallback when `limits` is absent: `five_hour` / `seven_day` `{utilization, resets_at}` (`five_hour` can be null). Unknown fields ignored.

**Polling:** every 5 min while the app runs; also on hub open if the last success is > 60 s old. On network/5xx/429: exponential backoff up to 30 min. On 401/403: renew once (above); if that fails, the expired state.

**Caching:** last good result (numbers + timestamp, no secrets) in `~/.claude/claude-widget/limits.json`, so the module shows last-known values with "updated 12m ago" after a relaunch.

**Display:** one ring per window from the feed (e.g. "week 78 %", "Fable · week 100 %"), the active limit emphasized, and "resets in …" for the soonest reset. Failure states never break the rest of the hub: "Limits unavailable" in secondary text.

**Openness for later providers** [proposed]: the model is a list of `{provider, windows: [{label, percent, resetsAt}]}` and the module renders whatever providers exist. No plugin protocol now — just a data shape Codex can fill later.

**Setting:** "Show Claude limits" (default on). Turning it off stops all Keychain reads and network calls.

## 8. Answer from the notch (local socket) [Gleb chose the socket]

**What the docs confirm** (code.claude.com/docs/en/hooks, read 2026-11-17): a `PermissionRequest` command hook can return a decision; the hook must be **synchronous** (async hooks can't affect Claude). Output shape:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the notch"}}}
```

Hooks fire in the terminal, IDE extensions and the desktop app. **Not documented:** whether Claude's own permission prompt waits while the hook runs, and what happens to the hook if Gleb answers the normal prompt first. The design below is safe either way; §11 makes measuring it the first build task.

**Hook config change.** Only the `PermissionRequest` entry becomes synchronous (`async` removed, `timeout: 60`). All other entries stay async. `isInstalled` additionally requires the PermissionRequest entry to be synchronous, so an old install simply shows **Install hooks** again (Install already replaces our own entries); no separate "update" state [proposed]. The installer never edits `settings.json` without a click and backs it up first, as today.

**Current state on Gleb's Mac (2026-11-17):** `~/.claude/settings.json` has `"hooks": {}` — no widget hooks (and no other hooks) are installed, the newest widget backup (2026-10-29) holds the 9 async widget entries, the state dir is empty, and the app isn't running. The removal was incidental, not because the hooks caused problems [Gleb]. Setup for project 1 is a fresh **Install**.

**What Gleb sees before Allow** [proposed]: the notch must show at least what Claude's own prompt shows for that decision, never a truncated version.
- The socket request carries `tool_input` (capped at 8 KB) instead of only `tool_display`.
- Allow is offered from the notch only when the whole request is visible: Bash (full command, wrapped; long commands open the hub row instead of the pill), WebFetch/WebSearch (URL/query), MCP tools (name + compact arguments, ≤ 3 lines).
- Everything else (Edit, Write, NotebookEdit, unknown tools): shows file/tool + a short summary with **Deny** and **Open** (focus the session's app) — no Allow, because a diff doesn't fit the notch.
- The pill shows Allow only when the request fits on one line; otherwise it shows **Review** (expands the hub to the row) and **Deny**.

**Socket.** `~/.claude/claude-widget/run/approve.sock` (well under the 104-byte path limit). The app creates `run/` with mode 0700, removes a stale socket file on launch (never a live one: a second instance backs off until the first is gone), binds, and unlinks on quit.

**Hook flow** (`PermissionRequest` only):
1. Write the session state file exactly as today (needs-you).
2. If `tool_name` is `AskUserQuestion` or `ExitPlanMode` → exit 0, no output (normal flow).
3. `connect()`; on any failure → exit 0, no output. Must add < 20 ms when the app isn't running.
4. Check the peer is the same user (`getpeereid` uid == own uid); otherwise exit 0, no output. (Trust boundary note: a process running as Gleb could already edit `settings.json`, so the socket adds no new hole; the uid check keeps it that way.)
5. Send one JSON line: `{"v":1,"id":"<uuid>","session_id","agent_id"?,"cwd","tool_name","tool_display","owner_bundle_id"}`.
6. Wait ≤ **500 ms** for `{"ack":true}` or `{"pass":true}`. Pass, timeout or EOF → exit 0, no output.
7. After ack, wait ≤ **30 s** for `{"decision":"allow"|"deny"}` or `{"pass":true}`. Timeout/EOF/pass → exit 0, no output. Allow/deny → print the exact JSON above, exit 0.

**App side.** Accept connections off the main thread; hand requests to the UI on main.
- Reply **pass** immediately when: "Answer from the notch" is off; or the session's owning app is frontmost (`NSWorkspace.frontmostApplication.bundleIdentifier == owner_bundle_id`) — Gleb is already looking at it [proposed; for the Claude desktop app this is a heuristic, since it hosts several sessions].
- Otherwise **ack** and show the pill + inline row buttons.
- While a request is pending, if the owning app becomes frontmost → send **pass** at once, so the normal prompt appears without waiting out the 30 s.
- Dismiss the request UI when: Gleb clicks Allow/Deny (send decision); the hook's connection closes (Claude moved on, Gleb answered elsewhere, or the hook was killed); the session leaves needs-you; or 30 s pass (send pass).
- Several pending requests: oldest first in the pill with a "+N" count; every pending request also shows inline in its Agents row.

**Setting:** "Answer permission prompts from the notch" (default on once hooks are updated).

## 9. Settings and the rest of the app

- The popover is removed. A standard macOS Settings window (SwiftUI grouped `Form`) opens from the critter's right-click menu and a small gear in the Limits module. Opening it activates the app (normal for a settings window).
- Sections: **General** (Launch at login) · **Notch** (Open on hover · Show alerts proactively · Answer permission prompts) · **Limits** (Show Claude limits) · **Phone** (existing ntfy controls, unchanged) · **Hooks** (status · Install / Remove; Install also updates an old install, R10).
- Minimum macOS becomes **26.0**: `Package.swift` platforms and `LSMinimumSystemVersion` in `scripts/bundle.sh`.
- README (done): replaced "Hooks are all async, so they add zero latency" with the accurate statement (all async except PermissionRequest, which waits only while the app is running, you're not in the session's app and the alert or the hub is visible, capped at 30 s); documented the limits feed (undocumented endpoints; the widget copies Claude Code's sign-in from the Keychain into its own entry and renews that copy, §7; sends it only to Anthropic); macOS 26 requirement.
- Unchanged: hook → state-file pipeline, subagent tracking, click-to-focus, ntfy phone alerts (they still fire on needs-you/finished), staleness GC, `simulate.sh`, DMG script.

## 10. Edge cases

| Case | Behaviour |
|---|---|
| App not running, Claude asks permission | `connect()` fails → normal prompt, no added delay |
| App running but hung | no ack within 500 ms → normal prompt |
| Gleb answers in the terminal/desktop first | hook connection closes or session leaves needs-you → pill dismissed |
| Hook killed / times out | connection EOF → pill dismissed |
| Two sessions ask at once | queued; "+1" in pill; both actionable inline in Agents rows |
| Subagent asks permission | same flow; row shows under its parent session |
| `AskUserQuestion` / `ExitPlanMode` | hook passes immediately; pill shows info-only needs-you |
| Usage feed changes shape / goes away | "Limits unavailable"; nothing else affected |
| Sign-in expired | renew once; if renewal fails and terminal Claude has no newer sign-in: "Sign-in expired · run /login in terminal Claude" |
| Display change / lid close while hub open | hub closes; geometry recomputed (as `NotchMetrics` does today) |
| Fullscreen app | hover-open disabled; pills still shown (window recipe from `macos-menubar-app-gotchas`: `.screenSaver` level + `.canJoinAllSpaces`, no `.fullScreenAuxiliary`) |
| Reduce Motion | fades only |

## 11. Verification

**First build task — measure before relying on it.** In a scratch directory with a project-level `.claude/settings.json`, register a synchronous `PermissionRequest` hook that sleeps 5 s and logs timestamps. Trigger a permission prompt in (1) the terminal CLI and (2) the desktop app, **in Gleb's real permission mode** (`defaultMode: "auto"`, `skipAutoPermissionPrompt: true`) as well as default mode. Record: does the hook fire at all in auto mode / the desktop app? Does the normal prompt appear immediately or after the hook returns? What happens to the hook — and to a decision it prints — if the prompt is answered first? Also make one live usage-feed call (§7). Write the results into this spec.

**Build order** [proposed]: hub shell + agents + limits first, then answer-from-notch (§8). Answer-from-notch is committed [Gleb: "we need the function"]; the measurement decides *how*, not *whether*. Only if it shows the hook can't fire where Gleb works (desktop app / auto mode), or that a late notch answer could override an answer he already gave elsewhere, stop and bring the results to Gleb rather than shipping a weaker version.

**Unit tests (ClaudeWidgetCore):**
- Usage response parsing: full response; missing windows; null optional windows; unknown fields; malformed JSON; reset-time formatting.
- Approval messages: encode/decode round-trip; decision output is byte-for-byte the documented JSON for allow and deny.
- Pass rules: `AskUserQuestion` / `ExitPlanMode` pass; other tools don't.
- Hooks merger: PermissionRequest entry is synchronous with `timeout: 60`; all other entries stay async; an old async PermissionRequest entry reports "needs update"; **negative:** other tools' hooks (Superset, good-eye) are never flagged or modified.

**Hook process tests** (spawn the built hook with a test socket path):
- No socket → exits 0, empty stdout, in < 50 ms.
- Socket that never replies → exits after ~500 ms, empty stdout.
- Ack then allow → exact allow JSON. Ack then deny → exact deny JSON.
- Ack then close → empty stdout.

**Manual / visual:** extend `scripts/simulate.sh` with a fake permission request sent to the socket, so the pill and inline buttons can be demoed without a real session. Screenshots via `screencapture -x -R …` run outside the Bash sandbox (recipe in memory notes).

## 12. Success criteria

1. Hovering the notch opens the hub after a short pause; moving away closes it; sweeping along the menu bar never opens it.
2. In another app, a Claude permission prompt shows the pill with Allow/Deny within ~0.5 s; Allow lets Claude continue without touching the terminal; Deny gives Claude the denial.
3. With the app quit, Claude's prompts behave exactly as without the widget (no noticeable delay).
4. Switching to the session's app while a request is pending makes the normal prompt appear right away.
5. The limits module shows the same limits and % as claude.ai's usage page, with reset time; keeps working across an 8-hour access-token expiry (it renews itself); shows last-known values after relaunch; shows "unavailable" on failure with everything else working.
6. Typing in another app is never interrupted by the hub or pills.
7. With no notch, clicking the critter opens the hub under it.
8. `swift build && swift test` green.

## 13. Left to the builder

Exact sizes, paddings, spring constants (start from the spike values above), type and file names, how the code is split between Core and the app, the fullscreen-detection method, how the "+N" queue looks, socket I/O style in the hook (blocking with `poll()` deadlines is fine), and how the hub panel is structured (one panel with hidden/pill/expanded states is the expected shape, replacing `NotchPanelController` + `PeekView`).

## 14. Open risks

- **Usage feed is undocumented** — it can change or disappear; handled by the "unavailable" state.
- **Prompt timing with a synchronous hook** is undocumented — measured in the first task.
- **Keychain prompt assumption** (reading via `/usr/bin/security` avoids a prompt) — verified on first build.
- **Ad-hoc signing** — unchanged from today; matters only for distribution.

## 15. Measurement results (2026-11-17)

**Limits (go, via renewal — §7):**

| Check | Result |
|---|---|
| Terminal Claude's saved sign-in before `/login` | empty (cleared 2026-11-16); usage feed → 401 |
| Desktop-app sessions | no token in the hook environment (the host refreshes auth); `ANTHROPIC_BASE_URL` is `https://api.anthropic.com` |
| `claude setup-token` year-long token | usage feed → **403** (scope too narrow) — route rejected |
| Terminal Claude's sign-in after `/login` | usage feed → **200**; access token ≈ 8 h, refresh token ≈ 30 days |
| Renewal `POST platform.claude.com/v1/oauth/token` | 403 with Python's default User-Agent; **200** with `claude-widget/0.1 (macOS)`; fields `access_token, refresh_token (rotated), expires_in=28800, refresh_token_expires_in, scope, token_type, token_uuid, account, organization` |
| Saving back to Keychain | blocked inside the Bash sandbox; outside it `security -i` on stdin saves ~1 KB values but **fails at 33 KB** (Claude Code's entry is 33,290 bytes) — hence the widget's own small entry |
| Usage feed shape | `limits` array (kind, group, percent, severity, resets_at, scope.model.display_name, is_active) + `five_hour`/`seven_day` objects + ~30 ignorable keys |

Incident during the renewal test: the renewed sign-in was not saved (sandbox + an unchanged-value write check that couldn't detect failure), so terminal Claude's refresh token was lost and it needs `/login` again. Lesson folded into §7: every Keychain write is verified with exit status, stderr and a read-back.

**Answer from the notch (go):** run as three Claude desktop-app Code sessions (Haiku) in `/private/tmp/claude/hook-test`, with a synchronous `PermissionRequest` probe hook that sleeps 5 s:

| Run | Mode | Probe answer | Result |
|---|---|---|---|
| d1 | default (asks) | allow after 5 s | hook fired (log: `permission_mode=default`); `touch` ran the same second the hook returned (5.03 s) with no click — **a hook allow is applied in the desktop app** |
| d2 | default (asks) | deny after 5 s | hook fired; command not run; Claude reported the reason verbatim: **"Denied from the notch"** |
| d3 | auto | — | **hook did not fire**: auto mode approved the command itself, no prompt was raised |

Not measured: whether the app's own prompt is visible while a synchronous hook runs, and what happens to a hook decision that arrives after the user already answered in the app. The §8 rules make that race unreachable through the widget — the app passes immediately when the session's owning app is frontmost, and passes the moment the owning app becomes frontmost — so those two rules are **mandatory**. In auto mode the widget only sees the prompts auto mode escalates to the user.

---

## 16. Deviations accepted during implementation

Controller rulings (ledger R10, R15–R20) and related accepted choices:

- **R10** — No separate Hooks "Update" button or state: Install re-merges the widget's entries, so an old install shows **Install hooks** again (§8) and Install updates it.
- **R15** — Allow is `.borderedProminent` tinted indigo, not `.glassProminent`: in the never-key panel the glass tint doesn't render, so Allow looked identical to Deny.
- **R16** — A pill carrying Allow / Deny / Review / Open does not expand on hover (§5 says pills expand), so buttons never move under the pointer; info-only pills still expand; Review opens the hub.
- **R17** — A request with no owner bundle id is passed immediately, since the two mandatory pass rules can't be applied without it.
- **R18** — `ApprovalServer`'s handler returns its on-close callback (the planned signature couldn't report a close).
- **R19** — When no pill will be shown (Show alerts proactively off) and the hub is not open, the request is passed immediately instead of held up to 30 s. Lifecycle cases (hub closes with pending requests, proactive turned off while closed, a request whose session has no row) also pass.
- **R20** — The approval pill is 540 pt wide (§5 says about 380) so a 60-character command fits on one line.
- **Hard-wrap renderer** — long commands wrap in exact columns with `↪` / `␣` markers so real newlines and spaces are never hidden; Allow is offered only for ASCII-only requests (non-ASCII gets Open + Deny).
- **0.5 s settle** — Allow is ignored for 0.5 s after the pending queue changes and after the owning row moves; Deny stays immediate.
- **MCP keys capped at 32** printable-ASCII characters; longer keys make the request Open-only.
- **Allow after layout** — Allow is offered only once the request text has been laid out at 8 columns or more.
- **Limits off** — a renewal already in flight finishes saving after Show Claude limits is turned off, so a rotated sign-in is never lost.

Final whole-branch review fixes:

- **Allow only while the whole request is on screen** — a request laid out in more than 10 rows gets Open (Review in the pill), and a row offers Allow only while its whole frame lies inside the Agents list's visible area (the list scrolls). Review scrolls the request's bottom edge into view.
- **Settle on appearing** — the 0.5 s Allow settle also restarts when the hub opens and when the approval pill appears.
- **WebFetch / WebSearch** — URL and query share Bash's 400-scalar cap.
- **Back to working after a notch answer** — after Allow or Deny for a main-loop request, the hook writes the session back to working (PostToolUse isn't hooked, so nothing else would until Claude's next event).
- **One socket owner** — the app never unlinks a socket another instance is serving; it backs off and takes over only once that socket is dead or gone.
- **Quit** — SIGTERM quits through the app (socket unlinked); quitting waits up to 5 s for a sign-in renewal in flight to be saved; usage and renewal requests time out (30 s per request, 60 s overall).
- **Hook process tests (§11) exist** — `Tests/ClaudeWidgetCoreTests/HookProcessTests.swift` spawns the built hook with its home redirected by `CFFIXED_USER_HOME` and a fake app on the socket: no socket, a silent socket, ack + allow / deny / close / pass, and the session write-back.
- **`--auto-answer`** (verification only) exists in debug builds only.

Follow-up hardening (2026-11-18):

- **Cross-instance renewal lock** — read own entry → renew → save runs under an `flock` on `~/.claude/claude-widget/run/renew.lock` (waits up to 90 s, else nothing is sent). Once the lock is held the entry is read again: a fresher sign-in another instance saved is used without sending anything; an unreadable entry sends nothing; a renewal whose own save failed is still the one renewed. The lock serializes renewals; it doesn't by itself stop a token being sent twice.
- **Spent-token marker** — after a 200 that rotated the refresh token, and before the save, the spent token's SHA-256 fingerprint (never the token) is written into `renew.lock`. No instance sends a token with that fingerprint: if the save failed, the entry still holds the spent token, and sending it would be refused (and, with reuse detection, could revoke the new one). That reads as no verdict ("Limits unavailable") while the renewing instance retries its save. A request that never reached the server, any non-200, and a 200 that didn't rotate leave no mark. A token whose renewal got no answer (a timeout) can still be sent again.
- **Quitting** — once `applicationShouldTerminate` runs, no renewal is sent: one waiting for another instance's lock gives up at once (nothing sent, nothing lost) instead of sending inside the 5 s quit wait; one already sent is still waited for.
- **Renewal verdicts** — only a 400/401/403 from the token endpoint reads as "Sign-in expired"; 429, 5xx, other statuses, timeouts and a renewed token already due read as "Limits unavailable". Inside the 10-minute spacing a renewal that worked never reads as refused. The spacing runs on a monotonic clock that keeps counting through sleep, so changing the Mac's clock can't shorten or stretch it. A 200 that isn't the documented shape drops no token: with both tokens they're kept with a 1-hour expiry; with only an access token the refresh token sent is kept (no rotation); with only a refresh token it's saved beside an expired access token (no verdict this poll, renewed next time); with neither it's no verdict.
- **Renewal sequence in Core** — `SignInRenewer` runs spacing → lock → re-read → marker check → send → mark → save, with the Keychain, the network and the quit/Limits-off check passed in as closures; `UsageMonitor` only supplies them. The sequence is tested end to end against fakes and a real lock file.
- **Approval rules in Core** — arrival passes (setting, owner frontmost, no owner, no pill and no open hub, …), owner-became-frontmost, the Allow gate and the 0.5 s settle are `ApprovalRules` / `AllowSettle`, unit-tested; the owner match is case-insensitive, so a case mismatch can only pass.
- **MCP argument types** — a non-string argument (bool, number, null, array, object) carries a type badge, so `true` and `"true"` never look alike next to Allow. An MCP request that can't be split back into a call is open-only (`ApprovalPolicy`), so Allow is never offered without the key column and badges.
- **Small items** — socket and line-reader timeouts clamp `.infinity`/huge values; a `limits` array keeps its valid entries beside a malformed one; `isInstalled` also requires the PermissionRequest `timeout: 60`; the Agents list is one scroll view (bounces only when it overflows), so rows are laid out once.
