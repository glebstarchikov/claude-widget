import AppKit
import SwiftUI
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusController: StatusItemController!
    private var model: AppModel!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notchAlertsEnabled": true])

        model = AppModel()
        statusController = StatusItemController()

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        statusController.onClick = { [weak self] in self?.togglePopover() }

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] old, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.model.sessions = new
            self.statusController.applyState(aggregate)
        }
        monitor.start()
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    func openPopover() {
        guard let button = statusController.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
