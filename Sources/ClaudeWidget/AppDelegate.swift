import AppKit
import Combine
import os
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
    private var usage: UsageMonitor!
    private var limitsToggle: AnyCancellable?
    private var approvals: ApprovalCoordinator!
    private var approvalsToggle: AnyCancellable?
    private var proactiveToggle: AnyCancellable?
    /// SIGTERM (`pkill`, `scripts/bundle.sh --install`) quits like the menu's Quit.
    private var sigterm: DispatchSourceSignal?
    /// Quit is waiting for a sign-in renewal (`applicationShouldTerminate`).
    private var quitWaiting = false
    /// How long quitting waits for a renewal in flight to be saved.
    private static let renewalQuitWait: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without this, SIGTERM kills the app outright: no unlinking the socket and
        // no waiting for a renewal's save. Routed through terminate, it's a normal quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Deferred, not called inline: terminate → .terminateLater waits inside this
        // main-queue block, which would keep the renewal (and its reply) from ever
        // running — a deadlock while a renewal is in flight.
        source.setEventHandler { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
        source.resume()
        sigterm = source

        UserDefaults.standard.register(defaults: [
            "notchProactiveEnabled": true,
            "hubHoverEnabled": true,
            "answerFromNotchEnabled": true,
            "limitsEnabled": true,
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
        hubModel.openSettings = { [weak self] in
            self?.hub.close()   // the hub floats above the Settings window
            self?.settingsWindow.show()
        }

        usage = UsageMonitor(model: hubModel)
        hub.onOpen = { [weak self] in
            self?.usage.refreshIfStale()
            self?.approvals.settle()   // the hub may open under a click aimed elsewhere
        }
        // Fires now with the saved setting, then on every change.
        limitsToggle = model.$limitsEnabled.sink { [weak self] enabled in
            if enabled { self?.usage.start() } else { self?.usage.stop() }
        }

        approvals = ApprovalCoordinator(model: hubModel, appModel: model)
        hubModel.answerApproval = { [weak self] id, allow in self?.approvals.answer(id: id, allow: allow) }
        hubModel.reviewApproval = { [weak self] id in self?.hub.review(approvalId: id) }
        hubModel.approvalRowTop = { [weak self] id, top in self?.approvals.rowPositioned(id: id, top: top) }
        hubModel.approvalPillShown = { [weak self] in self?.approvals.settle() }
        approvals.onChange = { [weak self] dismissing in self?.hub.approvalsChanged(dismissing: dismissing) }
        approvalsToggle = model.$answerFromNotch.sink { [weak self] enabled in
            self?.approvals.settingChanged(enabled: enabled)
        }
        proactiveToggle = model.$notchProactive.sink { [weak self] enabled in
            self?.approvals.proactiveChanged(enabled: enabled)
        }
        hub.onClose = { [weak self] in self?.approvals.hubClosed() }
        approvals.start()

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] _, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.hubModel.sessions = new
            self.approvals.sessionsChanged(new)
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

    /// A renewal in flight finishes and saves first (at most `renewalQuitWait`):
    /// the refresh token it sent is already spent, and only its reply is live.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let usage, usage.renewing else { return .terminateNow }
        if quitWaiting { return .terminateLater }
        quitWaiting = true
        Logger.limits.notice("quit waits for the sign-in renewal")
        Task { [weak self] in
            await usage.renewalFinished()
            self?.allowQuit()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.renewalQuitWait))
            if self?.quitWaiting == true { Logger.limits.error("quit stopped waiting for the renewal") }
            self?.allowQuit()
        }
        return .terminateLater
    }

    private func allowQuit() {
        guard quitWaiting else { return }
        quitWaiting = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        approvals.stop()
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
