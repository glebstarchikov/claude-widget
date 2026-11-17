# Claude Widget

The Claude Code critter, living in your Mac menu bar, and a Liquid Glass hub
that drops out of the notch. It mirrors your live Claude Code sessions, shows
how much of your Claude usage is left, and lets you answer Claude's permission
prompts without hunting for the right window.

Requires macOS 26 (Tahoe) or later.

## The hub

Rest the pointer on the notch (after a short pause, so brushing past doesn't
open it) or click the menu bar critter. Right-click the critter for
**Settings…** and **Quit**. On a Mac without a notch, or on an external
display, the hub opens under the critter instead. It never takes keyboard
focus, so it won't steal what you're typing.

- **Agents** — every live session with its state, model, owning-app icon,
  current tool, elapsed time, context use, and any subagents. Click a row to
  jump to that session's app.
- **Limits** — your Claude usage limits (for example "week 78 %" or
  "Fable · week 100 %"). See below.
- **Alerts** — interruption-worthy moments (Claude needs you, a long task
  finished) drop from the notch as a pill.

The critter itself:

- **Indigo, walking** — Claude is working
- **Orange, pulsing** — Claude needs you (permission or input)
- **Dim gray** — asleep, no sessions

Design system: [glebstar/design](https://github.com/glebstar) tokens (indigo
accent `#4b46f5`); Claude orange `#D97757` reserved for "Claude is asking".

## Install

    scripts/bundle.sh --install

This builds `Claude Widget.app`, installs it to `/Applications`, and launches
it. Then right-click the critter → **Settings…** → **Hooks** → **Install hooks**
(backs up `~/.claude/settings.json` first, then merges the hook entries
additively — your existing hooks are kept).

Hook latency: every hook runs in the background (`async`) except
`PermissionRequest`. That one waits for the widget only while the widget is
running, you're not in the session's app, and the alert or the hub is visible —
at most 30 seconds. If the widget isn't running it adds about 10 ms (warm).

## How it works

Claude Code hooks invoke a tiny compiled `claude-widget-hook` binary that writes
one JSON file per session (and per subagent) under
`~/.claude/claude-widget/state/`. The app watches that directory and drives the
critter and the hub. Session state is local only; the two optional network
features (Claude limits and your phone alerts) are described below.

Subagents are tracked in their own state files (keyed by `agent_id`), so a
session and its concurrently-running subagents never contend on the same file.

## Claude limits

The widget shows Claude's usage limits from Anthropic's usage feed, the same
numbers as claude.ai's usage page. To do that it needs a Claude sign-in, and
here is exactly how it handles one:

- You need terminal Claude signed in once (run `claude`, then `/login`). On
  first run the widget **copies** that sign-in into its own Keychain entry
  (`Claude Widget-usage-credentials`) and from then on **renews its own copy**
  about every 8 hours.
- It **never writes** Claude Code's own Keychain entry.
- **Consequence:** renewing replaces the shared renewal key, so terminal Claude
  will ask for `/login` again the next time it needs to renew.
- The renewal and usage endpoints (`platform.claude.com/v1/oauth/token`,
  `api.anthropic.com/api/oauth/usage`) are undocumented and may change. If they
  do, the module shows "Limits unavailable" and nothing else is affected.
- Tokens are only sent to Anthropic, never logged, and never written to a file.
  The cache at `~/.claude/claude-widget/limits.json` holds numbers only.
- **Settings → Limits → Show Claude limits** turns it off: no Keychain reads
  and no network calls, except that a renewal already in flight finishes saving
  so a rotated sign-in is never lost.

## Answer from the notch

When Claude asks permission and you're in another app, a pill drops from the
notch with **Allow / Deny** (or **Review** / **Open** when the full request
doesn't fit or can't be shown safely). Allow is offered only when the whole
request is visible: file edits and non-ASCII requests get Open + Deny, long
commands wrap in exact columns with `↪` / `␣` markers so nothing is hidden, and
a request taller than 10 rows, or partly scrolled out of the hub's list, gets
Open instead of Allow. After you answer, the session shows as working again. If
the session's own app is in front (or comes to the front) the widget steps
aside and Claude asks normally. Auto mode approves most actions itself; only
the prompts it escalates reach the notch.

## Settings

Right-click the critter → **Settings…**:

- **General** — Launch at login.
- **Notch** — Open on hover, Show alerts proactively, Answer permission prompts.
- **Limits** — Show Claude limits.
- **Phone** — push a notification to your phone when a session needs you or a
  long task finishes, via [ntfy](https://ntfy.sh). Flip it on, install the ntfy
  app on your phone, tap **+**, and paste the topic shown in Settings. Hit
  **Send test** to confirm the buzz. Only the project folder name leaves your
  Mac — never commands, paths, or prompts. On the public `ntfy.sh` server the
  topic name is your only secret (it's randomly generated and unguessable);
  point the `pushServer` default at your own ntfy instance for true end-to-end
  privacy.
- **Hooks** — Install / Remove the Claude Code hooks.

## Develop

    swift test                    # core logic tests
    swift run ClaudeWidget        # run unbundled (note: the menu bar icon only
                                  # shows from a bundled .app, so use bundle.sh)
    scripts/simulate.sh           # replay a fake session lifecycle, no tokens burned
    scripts/simulate.sh finished  # the long-task "Finished" alert
    scripts/simulate.sh approve   # a permission pill through the real hook
                                  # (variants: bash, multiline, edit, mcp)

## Sharing it with others

- **Build from source** — they `git clone`, run `scripts/bundle.sh --install`. No
  warnings (locally-built apps aren't quarantined).
- **Drag-to-install DMG** — `scripts/dmg.sh` produces `build/Claude Widget.dmg`
  (app + Applications shortcut). Because the app is only ad-hoc signed, the
  first launch needs a one-time **right-click → Open** to get past Gatekeeper.
- **Notarized DMG** (opens clean, no warning) — requires an Apple Developer
  Program membership: sign the app with a `Developer ID Application` cert, then
  `xcrun notarytool submit … --wait` and `xcrun stapler staple`. Then anyone can
  download and open it normally.

## Uninstall

Settings → Hooks → **Remove hooks**, quit the app, then delete
`/Applications/Claude Widget.app` and `~/.claude/claude-widget`, and remove the
widget's Keychain entry:

    security delete-generic-password -s "Claude Widget-usage-credentials"

## License

MIT — see [LICENSE](LICENSE). The license covers this project's code. The
critter and the Claude Code logo are Anthropic trademarks and are not licensed
here; this is an unofficial personal tool, not affiliated with Anthropic.
