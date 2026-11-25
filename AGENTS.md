# AGENTS.md

Claude Widget is a macOS menu bar app that mirrors Claude Code sessions: a critter in the menu bar, and a Liquid Glass hub from the notch with live sessions, Claude usage limits, what's playing and Allow or Deny for permission prompts. A small `claude-widget-hook` binary, run by Claude Code's hooks, writes session state that the app watches. Swift Package Manager, SwiftUI and AppKit, macOS 26 or later; public, and built from source with no release pipeline.

Write new agent instructions here. CLAUDE.md stays the single line `@AGENTS.md`.

## Checks

Before you finish, run what CI runs: `swift build && swift test`. They need a Mac on macOS 26.

`swift test` covers `ClaudeWidgetCore` and runs the built hook as a process; nothing tests the app's views. Check a change you can see in the real app with `scripts/bundle.sh --install`, run outside Claude Code's sandbox (it quits the app, rewrites `/Applications` and relaunches). Once hooks are installed, launching any build of the app, `swift run` included, copies its hook over the installed one, so a hook change reaches every Claude Code session on the Mac, this one included: get `swift test` green before you launch it.

## Layout

- Put new logic in `Sources/ClaudeWidgetCore`, the only target the tests import; the app and the hook stay thin.
- "spec §N" in a comment points into `docs/superpowers/specs/`. `HookInstaller.swift` cites the July design (`2026-07-10-claude-widget-design.md`); approvals, limits, the hook process tests and the R numbers (its §16) cite the notch hub (`2026-11-17-notch-hub-design.md`); `NotchStrip.swift` cites now playing. The July design predates the hub and still describes a popover and a notch peek; where a spec disagrees with the code or `GLOSSARY.md`, those win.
- `Vendor/MediaRemoteAdapter/` is a vendored fork with local patches; `VENDORED.md` lists them. Change it only on purpose.

## Conventions

- Use the terms in `GLOSSARY.md` (hub, pill, strip, conversion…) in code, UI text and commits, and none of its "Avoid" words.
- Once installed, the hook runs in every Claude Code session on the Mac, and `PermissionRequest` waits on it for up to 30 seconds. Keep it fast, and keep its stdout to the allow or deny JSON, or nothing, which hands the prompt back to Claude Code. Claude Code reads that stdout as the decision; `HookProcessTests` checks the exact bytes.
- One click on Allow must only ever approve a request the user could see in full. A change to when Allow is offered (`Approval.swift`, `ApprovalLayout.swift`, `ApprovalRules.swift`) comes with negative tests: requests that must not get Allow, like the truncated, control, bidi and invisible-character cases already there.
- Sign-in tokens go only to Anthropic, and never into a log, a file or a print; `OAuthCredential` redacts itself and the tests check it. The widget copies Claude Code's sign-in into its own Keychain entry (`Claude Widget-usage-credentials`) and never writes Claude Code's.
- Downloaded builds carry `com.apple.quarantine` on every file. Anything the app copies out of its bundle goes through `HelperCopy`, with a stamp from `HelperSources`; CI and source builds never have the flag, so a plain `copyItem` passes every check and breaks only for people who downloaded the app.
- Tests use fake tokens, temporary folders and `CFFIXED_USER_HOME` for the hook, never the real `~/.claude`, Keychain or network. New tests do the same.
