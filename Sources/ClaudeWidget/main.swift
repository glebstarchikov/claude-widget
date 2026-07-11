import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// AppDelegate() is @MainActor-isolated; main.swift's top level is a synchronous
// nonisolated context, so the isolated init needs an explicit assertion that
// we're already on the main thread here (true at process entry).
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
