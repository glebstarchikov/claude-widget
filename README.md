# Claude Widget

A menu bar companion for Claude Code, for anyone who runs long Claude sessions and wants to know their status at a glance.

No screenshot here: the app runs only on macOS, and this copy was not built or captured on a Mac.

Claude Code sessions run in a terminal you might not be watching. Claude Widget mirrors them in the menu bar: a critter that walks while Claude works, turns orange and pulses when Claude needs you, sits idle when a session is open but Claude is quiet, and sleeps when nothing is running. On a Mac with a notch, interruption-worthy moments slide out from under the notch as a Dynamic Island-style peek, and clicking the critter opens a session list with state, model, current tool, time since the last update, context size, and any subagents running underneath.

States at a glance:

- Indigo, walking: Claude is working.
- Orange, pulsing: Claude needs you (permission or input).
- Indigo, dimmer, idle: a session is open and Claude is ready, or waiting after it finishes.
- Dim gray: asleep, no sessions.
- Hover the notch: reveal a live status peek, with a soft haptic, while Notch peek is on (the default). The peek needs a display with a notch.

Claude Code hooks invoke a small compiled `claude-widget-hook` binary that writes one JSON file per session under `~/.claude/claude-widget/state/`, and one per subagent under `~/.claude/claude-widget/state/subagents/`. The app watches those directories and drives the menu bar critter, the notch peek, and the popover. No API keys and no telemetry. It reads local session state only, unless you turn on Notify my phone, which posts to an ntfy topic (off by default).

## Stack
Swift, SwiftUI, AppKit, Swift Package Manager. macOS 14 or later.

## Status
Maintained, Nov 2026.

## Getting started
On a Mac:

```sh
scripts/bundle.sh --install
```

This builds `Claude Widget.app`, installs it to `/Applications`, and launches it. The critter shows in the menu bar. Then click the critter, choose Install hooks (this backs up `~/.claude/settings.json` first, then merges the hook entries additively, keeping your existing hooks). Hooks are async, so Claude Code does not wait on them.

Build and core tests (the commands CI runs):

```sh
swift build
swift test
```

`swift build` compiles the app and the hook. `swift test` runs the core logic tests. Success is a run with no failures.

Develop locally:

```sh
swift run ClaudeWidget        # menu bar critter, no Finder icon; Launch at login needs the bundled app
scripts/simulate.sh           # replay a fake session lifecycle, no tokens burned (the app has to be running)
scripts/simulate.sh finished  # the long-task "Finished" peek (app running, display with a notch)
```

`scripts/simulate.sh` expects a debug build of the hook (`swift build`).

To uninstall: open the popover, choose Remove, quit the app, then delete `/Applications/Claude Widget.app` and `~/.claude/claude-widget`.

## License
MIT, see [LICENSE](LICENSE). The license covers this project's code only. The critter and the Claude Code logo are Anthropic trademarks and are not licensed here; this is an unofficial personal tool, not affiliated with Anthropic.

---
Part of what I build at [glebstarchikov.nl](https://glebstarchikov.nl).
