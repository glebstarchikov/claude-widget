# AGENTS.md

Claude Widget is a macOS menu bar app that mirrors Claude Code sessions: a critter in the menu bar, and a Liquid Glass hub from the notch with live sessions, Claude usage limits, what's playing and Allow or Deny for permission prompts. A small `claude-widget-hook` binary, run by Claude Code's hooks, writes session state that the app watches. Swift Package Manager, SwiftUI and AppKit, macOS 26 or later; public, and built from source with no release pipeline.

Write new agent instructions here. CLAUDE.md stays the single line `@AGENTS.md`.

## Checks

Before you finish, run what CI runs: `swift build && swift test`. They need a Mac on macOS 26.

`swift test` covers `ClaudeWidgetCore` and runs the built hook as a process; nothing tests the app's views. Check a change you can see in the real app: `scripts/bundle.sh --install` replaces the copy in `/Applications` and relaunches it, and the app refreshes the installed hook binary at launch.

## Layout

- `Sources/ClaudeWidgetCore` holds the logic both executables share; `Sources/ClaudeWidget` is the app and `Sources/ClaudeWidgetHook` the hook. Put new logic in Core, where the tests can reach it.
- "spec §N" in a comment points into the dated spec for that feature in `docs/superpowers/specs/`: the notch hub for approvals and limits, now playing for the strip, the July design for hooks.
- `Vendor/MediaRemoteAdapter/` is a vendored fork with local patches; `VENDORED.md` lists them. Change it only on purpose.

## Conventions

- Use the terms in `GLOSSARY.md` (hub, pill, strip, conversion…) in code, UI text and commits, and none of its "Avoid" words.
- Once installed, the hook runs in every Claude Code session on the Mac, and `PermissionRequest` waits on it for up to 30 seconds. Keep it fast, and keep its stdout to the allow or deny JSON: Claude Code reads that stdout as the decision. `HookProcessTests` checks the exact bytes.
- One click on Allow must only ever approve a request the user could see in full. A change to when Allow is offered (`Approval.swift`, `ApprovalLayout.swift`, `ApprovalRules.swift`) comes with negative tests: requests that must not get Allow, like the truncated, control, bidi and invisible-character cases already there.
- Sign-in tokens go only to Anthropic, and never into a log, a file or a print; `OAuthCredential` redacts itself and the tests check it. The widget copies Claude Code's sign-in into its own Keychain entry (`Claude Widget-usage-credentials`) and never writes Claude Code's.
- Tests use fake tokens, temporary folders and `CFFIXED_USER_HOME` for the hook, never the real `~/.claude`, Keychain or network. New tests do the same.
