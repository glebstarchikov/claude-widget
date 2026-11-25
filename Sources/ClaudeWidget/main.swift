import AppKit
import ClaudeWidgetCore

// Build scripts invoke the app binary with asset-generation flags; handle those
// and exit before any UI spins up. See DevTools.swift.
if DevTools.run(CommandLine.arguments) { exit(0) }

// Stamp the bundle's helpers now, before AppDelegate (whose model copies the hook)
// and before now playing starts, which may be days later. Static lets are lazy.
_ = HelperSources.hookStamp
_ = HelperSources.adapterStamp

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// AppDelegate() is @MainActor-isolated; main.swift's top level is a synchronous
// nonisolated context, so the isolated init needs an explicit assertion that
// we're already on the main thread here (true at process entry).
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
