# Claude Widget

The Claude Code critter, living in your Mac menu bar. It mirrors your live
Claude Code sessions — walks while Claude works, turns orange and pulses when
Claude needs you, sleeps when nothing is running. Interruption-worthy moments
slide out from under the notch as a Dynamic Island-style peek.

Click the critter for a session list: every running session with its state,
model, current tool, elapsed time, and any subagents running under it.

- **Indigo, walking** — Claude is working
- **Orange, pulsing** — Claude needs you (permission or input)
- **Dim gray** — asleep, no sessions
- **Hover the notch** — reveal a live status peek any time (with a soft haptic)

Design system: [glebstar/design](https://github.com/glebstar) tokens (indigo
accent `#4b46f5`); Claude orange `#D97757` reserved for "Claude is asking".

## Install

    scripts/bundle.sh --install

This builds `Claude Widget.app`, installs it to `/Applications`, and launches
it. Then click the critter → **Install hooks** (backs up `~/.claude/settings.json`
first, then merges the hook entries additively — your existing hooks are kept).
Hooks are all `async`, so they add zero latency to Claude sessions.

## How it works

Claude Code hooks invoke a tiny compiled `claude-widget-hook` binary that writes
one JSON file per session (and per subagent) under
`~/.claude/claude-widget/state/`. The app watches that directory and drives the
menu bar critter, the notch peek, and the popover. No network, no API keys,
no telemetry — it only reads local session state.

Subagents are tracked in their own state files (keyed by `agent_id`), so a
session and its concurrently-running subagents never contend on the same file.

## Settings (in the popover)

- **Launch at login** — start the widget automatically.
- **Notch peek** — master switch for the notch (hover reveal + proactive peeks).
- **Show proactively** — when the notch is on, whether it also pops up on its
  own for needs-you / finished events (off = hover-only).
- **Notify my phone** — push a notification to your phone when a session needs
  you or a long task finishes, via [ntfy](https://ntfy.sh). Flip it on, install
  the ntfy app on your phone, tap **+**, and paste the topic shown in the popover.
  Hit **Send test** to confirm the buzz. Only the project folder name leaves your
  Mac — never commands, paths, or prompts. On the public `ntfy.sh` server the
  topic name is your only secret (it's randomly generated and unguessable); point
  the `pushServer` default at your own ntfy instance for true end-to-end privacy.

## Develop

    swift test                    # core logic tests
    swift run ClaudeWidget        # run unbundled (note: the menu bar icon only
                                  # shows from a bundled .app, so use bundle.sh)
    scripts/simulate.sh           # replay a fake session lifecycle, no tokens burned
    scripts/simulate.sh finished  # the long-task "Finished" peek

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

Popover → **Remove hooks**, quit the app, then delete
`/Applications/Claude Widget.app` and `~/.claude/claude-widget`.

## License

MIT — see [LICENSE](LICENSE). The license covers this project's code. The
critter and the Claude Code logo are Anthropic trademarks and are not licensed
here; this is an unofficial personal tool, not affiliated with Anthropic.
