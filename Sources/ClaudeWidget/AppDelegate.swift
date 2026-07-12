import AppKit
import SwiftUI
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusController: StatusItemController!
    private var model: AppModel!
    private var popover: NSPopover!
    private var notch: NotchPanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notchAlertsEnabled": true])

        model = AppModel()
        statusController = StatusItemController()

        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        statusController.onClick = { [weak self] in self?.togglePopover() }

        notch = NotchPanelController()
        notch.onTap = { [weak self] in self?.openPopover() }

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] old, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.model.sessions = new
            self.statusController.applyState(aggregate)
            self.notch.resolveIfSticky(aggregate: aggregate)
            for peek in peeks {
                switch peek {
                case .needsYou(let session):
                    self.notch.showNeedsYou(session)
                case .finished(let session, let duration):
                    self.notch.showFinished(session, duration: duration)
                }
            }
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
