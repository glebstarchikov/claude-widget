import Foundation

/// An sRGB color with channels in 0...1, free of AppKit so theme logic stays testable.
public struct RGB: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Parses `#RRGGBB` (case-insensitive); anything else is nil.
    public init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), hex.dropFirst().allSatisfy(\.isHexDigit), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255,
                  g: Double((value >> 8) & 0xFF) / 255,
                  b: Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB`, uppercase, each channel rounded to the nearest integer.
    public var hex: String {
        func byte(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// WCAG 2 relative luminance.
    public var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG 2 contrast ratio, 1...21, symmetric.
    public func contrast(with other: RGB) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Linear mix toward `other`: 0 is self, 1 is `other`.
    public func mixed(with other: RGB, fraction: Double) -> RGB {
        RGB(r: r + (other.r - r) * fraction, g: g + (other.g - g) * fraction, b: b + (other.b - b) * fraction)
    }

    /// Self if it already meets `minimum` against `background`; otherwise mixed toward `target`
    /// in 5 % steps until it does, stopping at `target` itself.
    public func fitted(against background: RGB, toward target: RGB, minimum: Double = 3) -> RGB {
        if contrast(with: background) >= minimum { return self }
        for step in 1...20 {
            let candidate = mixed(with: target, fraction: Double(step) * 0.05)
            if candidate.contrast(with: background) >= minimum { return candidate }
        }
        return target
    }
}

/// The accent themes the user can pick; `custom` uses their own color.
public enum ThemeID: String, CaseIterable, Sendable {
    case claude, lime, mint, ocean, indigo, violet, rose, system, custom

    /// Name shown in the theme picker.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .lime: return "Lime"
        case .mint: return "Mint"
        case .ocean: return "Ocean"
        case .indigo: return "Indigo"
        case .violet: return "Violet"
        case .rose: return "Rose"
        case .system: return "System"
        case .custom: return "Custom"
        }
    }
}

/// An accent color for each menu bar appearance.
public struct ThemePair: Equatable, Sendable {
    public let light: RGB
    public let dark: RGB
}

/// Theme colors and the bar backgrounds they must stay legible against.
public enum ThemePalette {
    /// Menu bar background in light appearance.
    public static let lightBar = RGB(hex: "#ECECEE")!
    /// Menu bar background in dark appearance.
    public static let darkBar = RGB(hex: "#26262A")!
    /// Near-black text color used on light accent fills.
    public static let darkText = RGB(hex: "#1D1D1F")!
    /// Pure white, used on dark accent fills.
    public static let white = RGB(hex: "#FFFFFF")!

    /// The custom theme color before the user picks one.
    public static let defaultCustom = RGB(hex: "#2BB3C0")!

    static let black = RGB(hex: "#000000")!

    private static func preset(_ light: String, _ dark: String) -> ThemePair {
        ThemePair(light: RGB(hex: light)!, dark: RGB(hex: dark)!)
    }

    /// The accent for `id`; `custom` is fitted to ≥ 3:1 on both bars, presets are fixed.
    public static func pair(for id: ThemeID, custom: RGB) -> ThemePair {
        switch id {
        case .claude: return preset("#C36B4E", "#D97757")
        case .lime: return preset("#5E9425", "#6FAE2C")
        case .mint: return preset("#1C9571", "#1FA67E")
        case .ocean: return preset("#2C7FE0", "#2C7FE0")
        case .indigo: return preset("#4B46F5", "#8A86FF")
        case .violet: return preset("#9459E6", "#9459E6")
        case .rose: return preset("#DB4F84", "#DB4F84")
        case .system: return preset("#1D1D1F", "#F5F5F7")
        case .custom:
            return ThemePair(light: custom.fitted(against: lightBar, toward: black),
                             dark: custom.fitted(against: darkBar, toward: white))
        }
    }

    /// Text color on an accent `fill`: white, unless white has less than 3:1 contrast
    /// against the fill, in which case near-black.
    public static func onAccent(_ fill: RGB) -> RGB {
        fill.contrast(with: white) >= 3 ? white : darkText
    }
}

/// The seasonal window in which the critter wears a hat.
public enum NewYear {
    /// True from 15 December through 7 January inclusive, in `calendar`'s time zone.
    public static func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.month, .day], from: date)
        guard let month = c.month, let day = c.day else { return false }
        return (month == 12 && day >= 15) || (month == 1 && day <= 7)
    }
}
