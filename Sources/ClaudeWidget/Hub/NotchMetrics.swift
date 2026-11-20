import AppKit

/// Geometry of a notched display, derived from the screen so the hub's
/// placement under the notch and its hover zone can never drift apart.
struct NotchMetrics {
    static let minNotchWidth: CGFloat = 120
    static let fallbackNotchWidth: CGFloat = 200   // notch reported without auxiliary areas
    /// The hover zone reaches this far past each side of the notch.
    static let hoverSidePadding: CGFloat = 16

    let screen: NSScreen
    /// Menu bar height on this display (the notch's height).
    let topInset: CGFloat
    let notchWidth: CGFloat

    /// The first notched display, or `screen` if it has a notch. Nil otherwise.
    init?(screen: NSScreen? = nil) {
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              screen.safeAreaInsets.top > 0
        else { return nil }
        self.screen = screen
        self.topInset = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        self.notchWidth = (left > 0 && right > 0)
            ? max(Self.minNotchWidth, screen.frame.width - left - right)
            : Self.fallbackNotchWidth
    }

    /// Notch width + 16 pt each side, menu-bar height: dwelling here opens the hub.
    var hoverZone: NSRect {
        let width = notchWidth + 2 * Self.hoverSidePadding
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - topInset,
                      width: width, height: topInset)
    }
}
