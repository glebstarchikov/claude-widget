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

enum Theme {
    static let accentLight = NSColor(hex: 0x4B46F5)
    static let accentDark = NSColor(hex: 0x8A86FF)
    static let claudeOrange = NSColor(hex: 0xD97757)
    static let faintLight = NSColor(hex: 0x6F6E79)
    static let faintDark = NSColor(hex: 0x908F99)

    static let panelBg = NSColor(hex: 0x1C1B1F)
    static let panelBorder = NSColor(hex: 0x2A292E)
    static let panelFg = NSColor(hex: 0xECECEA)
    static let panelFaint = NSColor(hex: 0x908F99)

    static func monoFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Geist Mono", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func critterColor(state: AggregateState, darkAppearance: Bool) -> (color: NSColor, opacity: CGFloat) {
        switch state {
        case .asleep:
            return (darkAppearance ? faintDark : faintLight, 0.45)
        case .ready, .waiting:
            return (darkAppearance ? accentDark : accentLight, 0.70)
        case .working:
            return (darkAppearance ? accentDark : accentLight, 1.0)
        case .needsYou:
            return (claudeOrange, 1.0)
        }
    }
}
