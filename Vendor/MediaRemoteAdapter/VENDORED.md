# Vendored: mediaremote-adapter

- Upstream: https://github.com/ejbills/mediaremote-adapter
- Commit: `7d5b6cc`
- Vendored: 2026-11-21 (`Package.swift`, `LICENSE`, `Sources/`; no `.git`, no README)

Local patches, all in `Sources/MediaRemoteAdapter/MediaController.swift`:

1. `libraryPath` is public and resolves the dylib via `dladdr` on one of its own C symbols (the old `Bundle(for:)` lookup fails in the `.app`).
2. `perlScriptPath` is public and prefers `Bundle.main`'s `run.pl`, falling back to `Bundle.module` (whose accessor calls `fatalError` in an installed app).
3. `onListenerTerminated` fires for every listener exit or failed start the app didn't cause (current process only; no `eventCount` condition).

Update only on purpose; re-run the now-playing live check after any update.
