import AppKit
import Combine
import ServiceManagement
import ClaudeWidgetCore

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var hooksInstalled = false

    @Published var notchAlerts: Bool {
        didSet { UserDefaults.standard.set(notchAlerts, forKey: "notchAlertsEnabled") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Fails when running unbundled (swift run); reflect reality.
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private let installer = HookInstaller()

    init() {
        notchAlerts = UserDefaults.standard.bool(forKey: "notchAlertsEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshHooksStatus()
    }

    func installHooks() {
        try? installer.install()
        refreshHooksStatus()
    }

    func removeHooks() {
        try? installer.remove()
        refreshHooksStatus()
    }

    func refreshHooksStatus() {
        hooksInstalled = installer.isInstalled()
        if hooksInstalled {
            try? installer.refreshBinary()
        }
    }
}
