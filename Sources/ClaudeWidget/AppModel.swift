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

    /// When the notch is on, whether it also pops up on its own for needs-you /
    /// finished events (vs. only revealing on hover).
    @Published var notchProactive: Bool {
        didSet { UserDefaults.standard.set(notchProactive, forKey: "notchProactiveEnabled") }
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
        notchProactive = UserDefaults.standard.bool(forKey: "notchProactiveEnabled")
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
