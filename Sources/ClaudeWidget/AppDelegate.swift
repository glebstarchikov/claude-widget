import AppKit
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusController: StatusItemController!
    private var model: AppModel!
    private let hubModel = HubModel()
    private var hub: HubController!
    private let pushNotifier = PushNotifier()
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "notchProactiveEnabled": true,
            "hubHoverEnabled": true,
            "answerFromNotchEnabled": true,
            "pushEnabled": false,
        ])

        model = AppModel()
        statusController = StatusItemController()
        hub = HubController(model: hubModel, appModel: model)
        hub.start()

        statusController.onClick = { [weak self] in
            guard let self, let button = self.statusController.button else { return }
            self.hub.toggleFromStatusItem(button)
        }
        statusController.onRightClick = { [weak self] in self?.showStatusMenu() }
        settingsWindow = SettingsWindowController(model: model)
        if CommandLine.arguments.contains("--show-settings") { settingsWindow.show() }

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] _, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.hubModel.sessions = new
            self.statusController.applyState(aggregate)
            self.hub.resolvePills(aggregate: aggregate)
            for peek in peeks {
                self.pushNotifier.send(peek)
                switch peek {
                case .needsYou(let session):
                    self.hub.showPill(.needsYou(sessionId: session.sessionId))
                case .finished(let session, let duration):
                    self.hub.showPill(.finished(sessionId: session.sessionId, duration: duration))
                }
            }
        }
        monitor.start()

        if CommandLine.arguments.contains("--show-hub") { hub.showExpanded() }
    }

    private func showStatusMenu() {
        hub.close()   // the hub floats above menus; get it out of the way
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusController.showMenu(menu)
    }

    @objc private func openSettings() { settingsWindow.show() }
}
