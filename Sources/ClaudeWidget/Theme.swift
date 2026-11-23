import AppKit
import ClaudeWidgetCore

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

/// The current theme and whether the New Year hat is on. Views and the status item
/// read it; `AppModel` writes it whenever a setting changes.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var id: ThemeID = .claude
    @Published private(set) var pair: ThemePair = ThemePalette.pair(for: .claude, custom: ThemePalette.defaultCustom)
    @Published private(set) var hatOn = false

    private var hatSetting = true

    /// The New Year window, or `-newYearPreview YES` on the command line (for previews; no UI, no default).
    private static func seasonOn(_ now: Date) -> Bool {
        NewYear.isActive(on: now) || UserDefaults.standard.bool(forKey: "newYearPreview")
    }

    func apply(id: ThemeID, customHex: String, hatSetting: Bool, now: Date = Date()) {
        self.id = id
        pair = ThemePalette.pair(for: id, custom: RGB(hex: customHex) ?? ThemePalette.defaultCustom)
        self.hatSetting = hatSetting
        hatOn = hatSetting && Self.seasonOn(now)
    }

    /// Re-checks the New Year window (the date rolled over while running).
    func dayChanged(now: Date = Date()) {
        let on = hatSetting && Self.seasonOn(now)
        if on != hatOn { hatOn = on }
    }
}

@MainActor
enum Theme {
    nonisolated static let faintLight = NSColor(hex: 0x6F6E79)
    nonisolated static let faintDark = NSColor(hex: 0x908F99)
    static let needsYouRed = NSColor.systemRed

    private static func ns(_ c: RGB) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// The hub's accent (Allow fill, usage rings). System follows the macOS accent,
    /// read at call time so a change shows without a relaunch.
    static func accent(dark: Bool) -> NSColor {
        let store = ThemeStore.shared
        if store.id == .system { return NSColor.controlAccentColor }
        return ns(dark ? store.pair.dark : store.pair.light)
    }

    /// Label color on an `accent(dark:)` fill: white or near-black, whichever reads better.
    static func onAccent(dark: Bool) -> NSColor {
        let store = ThemeStore.shared
        if store.id == .system {
            // The macOS accent varies (yellow is light), so pick by contrast like the other themes.
            guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return NSColor.white }
            let fill = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
            return ns(ThemePalette.onAccent(fill))
        }
        return ns(ThemePalette.onAccent(dark ? store.pair.dark : store.pair.light))
    }

    static func critterColor(state: AggregateState, darkAppearance: Bool) -> (color: NSColor, opacity: CGFloat) {
        let store = ThemeStore.shared
        let themed = ns(darkAppearance ? store.pair.dark : store.pair.light)
        switch state {
        case .asleep:
            return (darkAppearance ? faintDark : faintLight, 0.45)
        case .ready, .waiting:
            return (themed, 0.70)
        case .working, .needsYou:
            return (themed, 1.0)
        }
    }
}
