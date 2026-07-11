import AppKit
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notchAlertsEnabled": true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.dashed",
                                           accessibilityDescription: "Claude Widget")

        monitor = SessionMonitor()
        monitor.onChange = { old, new, peeks in
            let aggregate = Aggregator.aggregate(new)
            NSLog("claude-widget: \(new.count) session(s), aggregate=\(aggregate), peeks=\(peeks.count)")
        }
        monitor.start()
    }
}
