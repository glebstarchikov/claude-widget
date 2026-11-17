import AppKit
import SwiftUI

/// Owns the single Settings window. The app has no SwiftUI `App`, so the
/// `Settings` scene is unavailable; this is a plain NSWindow hosting SettingsView.
@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Claude Widget Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.refreshHooksStatus()   // the window is reused; re-read on every open
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
