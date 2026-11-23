import AppKit
import Combine
import ServiceManagement
import ClaudeWidgetCore

@MainActor
final class AppModel: ObservableObject {
    @Published var hooksInstalled = false

    /// Hover the notch to open the hub (pills and the critter click work either way).
    @Published var hubHoverEnabled: Bool {
        didSet { UserDefaults.standard.set(hubHoverEnabled, forKey: "hubHoverEnabled") }
    }

    /// Answer permission prompts from the notch (ApprovalCoordinator); off passes every request back to Claude Code.
    @Published var answerFromNotch: Bool {
        didSet { UserDefaults.standard.set(answerFromNotch, forKey: "answerFromNotchEnabled") }
    }

    /// When the notch is on, whether it also pops up on its own for needs-you /
    /// finished events (vs. only revealing on hover).
    @Published var notchProactive: Bool {
        didSet { UserDefaults.standard.set(notchProactive, forKey: "notchProactiveEnabled") }
    }

    /// Show Claude's usage limits in the hub. Off stops every Keychain read and network call for them.
    @Published var limitsEnabled: Bool {
        didSet { UserDefaults.standard.set(limitsEnabled, forKey: "limitsEnabled") }
    }

    /// Show what's playing in the hub. Off stops the adapter's perl process.
    @Published var nowPlayingEnabled: Bool {
        didSet { UserDefaults.standard.set(nowPlayingEnabled, forKey: "nowPlayingEnabled") }
    }

    /// Also show it around the closed notch.
    @Published var nowPlayingNotchEnabled: Bool {
        didSet { UserDefaults.standard.set(nowPlayingNotchEnabled, forKey: "nowPlayingNotchEnabled") }
    }

    /// The listener kept dying and was given up on (NowPlayingMonitor). Not persisted.
    @Published var nowPlayingUnavailable = false

    @Published var theme: ThemeID {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme"); applyTheme() }
    }

    /// `#RRGGBB`, used when `theme` is `.custom`.
    @Published var customThemeColor: String {
        didSet { UserDefaults.standard.set(customThemeColor, forKey: "themeCustomColor"); applyTheme() }
    }

    /// Whether the critter wears a hat during the New Year window.
    @Published var newYearHat: Bool {
        didSet { UserDefaults.standard.set(newYearHat, forKey: "newYearHat"); applyTheme() }
    }

    private func applyTheme() {
        ThemeStore.shared.apply(id: theme, customHex: customThemeColor, hatSetting: newYearHat)
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
        hubHoverEnabled = UserDefaults.standard.bool(forKey: "hubHoverEnabled")
        answerFromNotch = UserDefaults.standard.bool(forKey: "answerFromNotchEnabled")
        notchProactive = UserDefaults.standard.bool(forKey: "notchProactiveEnabled")
        limitsEnabled = UserDefaults.standard.bool(forKey: "limitsEnabled")
        nowPlayingEnabled = UserDefaults.standard.bool(forKey: "nowPlayingEnabled")
        nowPlayingNotchEnabled = UserDefaults.standard.bool(forKey: "nowPlayingNotchEnabled")
        theme = ThemeID(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .claude
        let storedColor = UserDefaults.standard.string(forKey: "themeCustomColor") ?? ""
        customThemeColor = RGB(hex: storedColor) == nil ? ThemePalette.defaultCustom.hex : storedColor
        newYearHat = UserDefaults.standard.bool(forKey: "newYearHat")
        pushEnabled = UserDefaults.standard.bool(forKey: "pushEnabled")
        pushTopic = UserDefaults.standard.string(forKey: "pushTopic") ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        applyTheme()
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
