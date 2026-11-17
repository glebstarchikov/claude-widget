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
    private var hover: NotchHoverController!
    private let pushNotifier = PushNotifier()
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "notchAlertsEnabled": true,
            "notchProactiveEnabled": true,
            "hubHoverEnabled": true,
            "answerFromNotchEnabled": true,
            "pushEnabled": false,
        ])

        model = AppModel()
        statusController = StatusItemController()

        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        statusController.onClick = { [weak self] in self?.togglePopover() }
        statusController.onRightClick = { [weak self] in self?.showStatusMenu() }
        settingsWindow = SettingsWindowController(model: model)
        if CommandLine.arguments.contains("--show-settings") { settingsWindow.show() }

        notch = NotchPanelController()
        notch.onTap = { [weak self] in self?.openPopover() }

        hover = NotchHoverController()
        hover.onHoverIn = { [weak self] in
            guard let self, let peek = self.currentStatusPeek() else { return }
            self.notch.showHover(title: peek.title, detail: peek.detail, state: peek.state)
        }
        hover.onHoverOut = { [weak self] in self?.notch.hideHover() }
        hover.start()

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] old, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.model.sessions = new
            self.statusController.applyState(aggregate)
            self.notch.resolveIfSticky(aggregate: aggregate)
            for peek in peeks {
                self.pushNotifier.send(peek)
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

    /// The peek shown when the notch is hovered: a glanceable summary of the
    /// current session state.
    private func currentStatusPeek() -> (title: String, detail: String, state: AggregateState)? {
        let sessions = monitor.sessions
        switch Aggregator.aggregate(sessions) {
        case .needsYou:
            guard let s = sessions.first(where: { $0.state == .needsYou }) else { return nil }
            let detail = [s.projectName, s.message].compactMap { $0 }.joined(separator: " · ")
            return ("Needs you", detail, .needsYou)
        case .working:
            let working = sessions.filter { $0.state == .working }
            let name = working.first?.projectName ?? ""
            let detail = working.count > 1 ? "\(name) +\(working.count - 1) more" : name
            return ("Working", detail, .working)
        case .waiting:
            return ("Waiting for you", sessions.first { $0.state == .waiting }?.projectName ?? "", .waiting)
        case .ready:
            return ("Ready", sessions.first?.projectName ?? "", .ready)
        case .asleep:
            return ("Sleeping", "no active sessions", .asleep)
        }
    }

    private func showStatusMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusController.showMenu(menu)
    }

    @objc private func openSettings() { settingsWindow.show() }

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
