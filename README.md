# Claude Widget

A menu bar companion for Claude Code, for anyone who runs long Claude sessions and wants to know their status at a glance, and answer Claude without hunting for the right window.

Claude Code sessions run in a terminal or app you might not be watching. Claude Widget mirrors them in the menu bar: a critter that walks while Claude works, turns orange and pulses when Claude needs you, and sleeps when nothing is running. Rest the pointer on the notch, or click the critter, and a Liquid Glass hub drops out of the notch with every live session (state, model, the app it runs in, current tool, elapsed time, context use, subagents), your Claude usage limits, and any permission prompt waiting for you. Requires macOS 26 (Tahoe) or later.

States at a glance:

- Indigo, walking: Claude is working.
- Orange, pulsing: Claude needs you (permission or input).
- Dim gray: asleep, no sessions.
- Rest on the notch: the hub opens after a short pause, so brushing past doesn't open it. It never takes keyboard focus.

Claude Code hooks invoke a small compiled `claude-widget-hook` binary that writes one JSON file per session (and per subagent) under `~/.claude/claude-widget/state/`. The app watches that directory and drives the critter and the hub. Session state never leaves your Mac and there is no telemetry; the only network calls are the two optional features below (Claude limits, and phone alerts if you turn them on).

## Answer from the notch
When Claude asks permission and you're in another app, a pill drops from the notch with Allow and Deny. Allow is offered only when you can see the whole request: file edits and non-ASCII requests get Open and Deny, long commands wrap in exact columns with `↪` and `␣` markers so nothing hides at a line break, and anything taller than 10 rows or partly scrolled out of view gets Open or Review instead. If the session's own app is in front, or comes to the front, the widget steps aside and Claude asks the normal way. Auto mode approves most actions itself; only the prompts it escalates reach the notch.

## Claude limits
The hub shows your Claude usage limits from Anthropic's usage feed, the same numbers as claude.ai's usage page (for example "week 78 %" and "Fable · week 100 %"). How it handles your sign-in:

- Terminal Claude needs to be signed in once (`claude`, then `/login`). On first run the widget copies that sign-in into its own Keychain entry (`Claude Widget-usage-credentials`) and from then on renews its own copy, about every 8 hours. It never writes Claude Code's own Keychain entry.
- Renewing replaces the shared renewal key, so terminal Claude asks for `/login` again the next time it needs to renew.
- The usage and renewal endpoints (`api.anthropic.com/api/oauth/usage`, `platform.claude.com/v1/oauth/token`) are undocumented and may change. If they do, the hub shows "Limits unavailable" and nothing else is affected.
- Tokens only ever go to Anthropic, are never logged, and are never written to a file; `~/.claude/claude-widget/limits.json` holds numbers only. Settings, Limits, Show Claude limits turns it all off (a renewal already in flight still finishes saving, so a renewed sign-in is never lost).

## Stack
Swift, SwiftUI (Liquid Glass), AppKit, Swift Package Manager.

## Getting started
```sh
scripts/bundle.sh --install
```

This builds `Claude Widget.app`, installs it to `/Applications`, and launches it. Then right-click the critter, choose Settings…, and under Hooks choose Install hooks (this backs up `~/.claude/settings.json` first, then merges the hook entries additively, keeping your existing hooks). Every hook runs in the background except `PermissionRequest`, which waits for the widget only while it's running, you're not in the session's app, and the pill or hub is visible, at most 30 seconds. With the widget not running it adds about 10 ms.

Settings (right-click the critter): Launch at login; Open on hover, Show alerts proactively, Answer permission prompts; Show Claude limits; phone alerts via [ntfy](https://ntfy.sh) (only the project folder name leaves your Mac); Install or Remove hooks.

Develop and test locally:

```sh
swift test                    # core logic tests
swift run ClaudeWidget        # run unbundled (menu bar icon only shows from a bundled .app, so use bundle.sh for the real thing)
scripts/simulate.sh           # replay a fake session lifecycle, no tokens burned
scripts/simulate.sh finished  # the long-task "Finished" alert
scripts/simulate.sh approve   # a permission pill through the real hook (variants: bash, multiline, edit, mcp)
```

To uninstall: in Settings choose Remove hooks, quit the app, delete `/Applications/Claude Widget.app` and `~/.claude/claude-widget`, then remove the widget's sign-in with `security delete-generic-password -s "Claude Widget-usage-credentials"`.

## License
MIT, see [LICENSE](LICENSE). The license covers this project's code only. The critter and the Claude Code logo are Anthropic trademarks and are not licensed here; this is an unofficial personal tool, not affiliated with Anthropic.

---
Part of what I build at [glebstarchikov.nl](https://glebstarchikov.nl).
