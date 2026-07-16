# Claude Widget

A menu bar companion for Claude Code, for anyone who runs long Claude sessions and wants to know their status at a glance.

Claude Code sessions run in a terminal you might not be watching. Claude Widget mirrors them in the menu bar: a critter that walks while Claude works, turns orange and pulses when Claude needs you, and sleeps when nothing is running. Interruption-worthy moments slide out from under the notch as a Dynamic Island-style peek, and clicking the critter opens a session list with state, model, current tool, elapsed time, and any subagents running underneath.

States at a glance:

- Indigo, walking: Claude is working.
- Orange, pulsing: Claude needs you (permission or input).
- Dim gray: asleep, no sessions.
- Hover the notch: reveal a live status peek any time, with a soft haptic.

Claude Code hooks invoke a small compiled `claude-widget-hook` binary that writes one JSON file per session (and per subagent) under `~/.claude/claude-widget/state/`. The app watches that directory and drives the menu bar critter, the notch peek, and the popover. No network calls, no API keys, no telemetry: it only reads local session state.

## Stack
Swift, SwiftUI, Swift Package Manager.

## Getting started
```sh
scripts/bundle.sh --install
```

This builds `Claude Widget.app`, installs it to `/Applications`, and launches it. Then click the critter, choose Install hooks (this backs up `~/.claude/settings.json` first, then merges the hook entries additively, keeping your existing hooks). Hooks are all async, so they add zero latency to Claude sessions.

Develop and test locally:

```sh
swift test                    # core logic tests
swift run ClaudeWidget        # run unbundled (menu bar icon only shows from a bundled .app, so use bundle.sh for the real thing)
scripts/simulate.sh           # replay a fake session lifecycle, no tokens burned
scripts/simulate.sh finished  # the long-task "Finished" peek
```

To uninstall: open the popover, choose Remove hooks, quit the app, then delete `/Applications/Claude Widget.app` and `~/.claude/claude-widget`.

## License
MIT, see [LICENSE](LICENSE). The license covers this project's code only. The critter and the Claude Code logo are Anthropic trademarks and are not licensed here; this is an unofficial personal tool, not affiliated with Anthropic.

---
Part of what I build at [glebstarchikov.nl](https://glebstarchikov.nl).
