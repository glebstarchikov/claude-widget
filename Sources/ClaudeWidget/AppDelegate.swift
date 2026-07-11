import AppKit
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notchAlertsEnabled": true])

        statusController = StatusItemController()

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] old, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.statusController.applyState(aggregate)
            NSLog("claude-widget: \(new.count) session(s), aggregate=\(aggregate), peeks=\(peeks.count)")
        }
        monitor.start()
    }
}
