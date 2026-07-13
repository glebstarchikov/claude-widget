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

    @Published var pushEnabled: Bool {
        didSet {
            UserDefaults.standard.set(pushEnabled, forKey: "pushEnabled")
            if pushEnabled, (UserDefaults.standard.string(forKey: "pushTopic") ?? "").isEmpty {
                let topic = "claude-" + Self.randomTopicSuffix()
                UserDefaults.standard.set(topic, forKey: "pushTopic")
                pushTopic = topic
            }
        }
    }
    @Published var pushTopic: String

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
    private let notifier = PushNotifier()

    private static func randomTopicSuffix() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<12).compactMap { _ in chars.randomElement() })
    }

    func sendTestPush() { notifier.sendTest() }

    init() {
        notchAlerts = UserDefaults.standard.bool(forKey: "notchAlertsEnabled")
        notchProactive = UserDefaults.standard.bool(forKey: "notchProactiveEnabled")
        pushEnabled = UserDefaults.standard.bool(forKey: "pushEnabled")
        pushTopic = UserDefaults.standard.string(forKey: "pushTopic") ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshHooksStatus()
    }

    func installHooks() {
        do { try installer.install() } catch { report("install", error) }
        refreshHooksStatus()
    }

    func removeHooks() {
        do { try installer.remove() } catch { report("remove", error) }
        refreshHooksStatus()
    }

    private func report(_ verb: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't \(verb) hooks"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    func refreshHooksStatus() {
        hooksInstalled = installer.isInstalled()
        if hooksInstalled {
            try? installer.refreshBinary()
        }
    }
}
