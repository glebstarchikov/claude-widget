import AppKit
import ClaudeWidgetCore

enum CritterRenderer {
    static func image(pose: CritterPose, color: NSColor, opacity: CGFloat,
                      pointSize: CGFloat = 18, hat: Bool = false, badge: Bool = false) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / CritterGeometry.canvas.width
            context.scaleBy(x: scale, y: scale)
            context.saveGState()
            if hat { context.translateBy(x: 0, y: CritterGeometry.hatBodyShift) }
            let path = CGMutablePath()
            for rect in CritterGeometry.bodyRects(pose: pose) { path.addRect(rect) }
            for eye in CritterGeometry.eyeCutouts(pose: pose) { path.addRect(eye) }
            context.addPath(path)
            context.setFillColor(color.withAlphaComponent(opacity).cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
            if hat { drawHat(in: context, opacity: opacity) }
            if badge { drawBadge(in: context, hat: hat) }
            return true
        }
        return image
    }

    private static func circlePath(_ c: Circle2D, grownBy extra: CGFloat = 0) -> CGPath {
        let r = c.radius + extra
        return CGPath(ellipseIn: CGRect(x: c.center.x - r, y: c.center.y - r, width: r * 2, height: r * 2),
                      transform: nil)
    }

    /// The hat is drawn at the body's opacity so a sleeping critter carries no bright red.
    private static func drawHat(in context: CGContext, opacity: CGFloat) {
        let red = NSColor(srgbRed: 0xD9 / 255, green: 0x3A / 255, blue: 0x3A / 255, alpha: 1).cgColor
        let hairline = NSColor(white: 0, alpha: 0.35).cgColor
        let brim = CGPath(roundedRect: CritterGeometry.hatBrim, cornerWidth: 0.9, cornerHeight: 0.9, transform: nil)
        let parts: [(CGPath, CGColor)] = [
            (CritterGeometry.hatCone(), red),
            (brim, NSColor.white.cgColor),
            (circlePath(CritterGeometry.hatPom), NSColor.white.cgColor),
        ]
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.setAlpha(1) }
        for (path, fill) in parts {
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(hairline)
            context.setLineWidth(0.6)
            context.strokePath()
        }
    }

    private static func drawBadge(in context: CGContext, hat: Bool) {
        let dot = CritterGeometry.badge(hat: hat)
        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(circlePath(dot, grownBy: CritterGeometry.badgeGap))
        context.fillPath()
        context.restoreGState()
        context.addPath(circlePath(dot))
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fillPath()
    }
}
