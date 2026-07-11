import AppKit
import ClaudeWidgetCore

enum CritterRenderer {
    static func image(pose: CritterPose, color: NSColor, opacity: CGFloat,
                      pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / CritterGeometry.canvas.width
            context.scaleBy(x: scale, y: scale)
            let path = CGMutablePath()
            for rect in CritterGeometry.bodyRects(pose: pose) { path.addRect(rect) }
            for eye in CritterGeometry.eyeCutouts(pose: pose) { path.addRect(eye) }
            context.addPath(path)
            context.setFillColor(color.withAlphaComponent(opacity).cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        return image
    }
}
