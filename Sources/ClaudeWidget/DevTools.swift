import AppKit
import ClaudeWidgetCore

/// Off-screen asset generation invoked by the build scripts (`bundle.sh`,
/// `dmg.sh`), never at runtime. Kept out of `main.swift` so the app's entry
/// point stays just the runtime wiring.
enum DevTools {
    /// Handles a dev-tools flag if present. Returns true when it did (caller exits).
    static func run(_ arguments: [String]) -> Bool {
        if arguments.contains("--dump-poses") {
            dumpPoses(to: URL(fileURLWithPath: arguments.last!))
            return true
        }
        if let i = arguments.firstIndex(of: "--render-icon"), arguments.count > i + 1 {
            renderIcon(to: URL(fileURLWithPath: arguments[i + 1]))
            return true
        }
        if let i = arguments.firstIndex(of: "--render-dmg-bg"), arguments.count > i + 1 {
            renderDMGBackground(to: URL(fileURLWithPath: arguments[i + 1]))
            return true
        }
        return false
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    /// Dumps one PNG per critter pose/state for eyeballing the animation frames.
    private static func dumpPoses(to out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases: [(String, CritterPose, NSColor, CGFloat)] = [
            ("idle-accent-dark", .idle, Theme.accentDark, 0.70),
            ("walkA", .walkA, Theme.accentDark, 1.0),
            ("walkB", .walkB, Theme.accentDark, 1.0),
            ("needsyou-orange", .idle, Theme.claudeOrange, 1.0),
            ("blink", .blink, Theme.accentDark, 0.70),
            ("asleep-faint", .asleep, Theme.faintDark, 0.45),
        ]
        for (name, pose, color, opacity) in cases {
            let image = CritterRenderer.image(pose: pose, color: color, opacity: opacity, pointSize: 72)
            writePNG(image, to: out.appendingPathComponent("\(name).png"))
        }
    }

    /// Renders the app-icon iconset: a charcoal squircle with a white critter.
    private static func renderIcon(to out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let px = CGFloat(size)
            let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
                // Charcoal squircle + white critter — same black as the notch peek.
                let bg = NSBezierPath(roundedRect: rect.insetBy(dx: px * 0.06, dy: px * 0.06),
                                      xRadius: px * 0.22, yRadius: px * 0.22)
                NSColor(hex: 0x1C1B1F).setFill()
                bg.fill()
                let critter = CritterRenderer.image(pose: .idle, color: .white, opacity: 1.0, pointSize: px * 0.52)
                critter.draw(in: rect.insetBy(dx: px * 0.24, dy: px * 0.24))
                return true
            }
            writePNG(image, to: out.appendingPathComponent("icon_\(size)x\(size).png"))
        }
    }

    /// Renders the drag-to-install DMG background (app → Applications arrow).
    private static func renderDMGBackground(to out: URL) {
        // Render into a 2x bitmap but tag it as a 600x400-point image (144 DPI), so
        // Finder maps 1 image-point = 1 window-point AND stays crisp on Retina.
        let w: CGFloat = 600, h: CGFloat = 400
        let scale = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(w) * scale, pixelsHigh: Int(h) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        NSColor(hex: 0xFCFCFB).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        // Icons sit at point (150,200) and (450,200); the arrow spans between them.
        Theme.accentLight.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = 7
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: 240, y: 200))
        shaft.line(to: NSPoint(x: 356, y: 200))
        shaft.stroke()
        let head = NSBezierPath()
        head.lineWidth = 7
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.move(to: NSPoint(x: 340, y: 220))
        head.line(to: NSPoint(x: 360, y: 200))
        head.line(to: NSPoint(x: 340, y: 180))
        head.stroke()

        let para = NSMutableParagraphStyle(); para.alignment = .center
        "Claude Widget".draw(in: NSRect(x: 0, y: 336, width: w, height: 32), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor(hex: 0x4B46F5), .paragraphStyle: para,
        ])
        "drag the critter into Applications".draw(in: NSRect(x: 0, y: 40, width: w, height: 22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(hex: 0x6F6E79), .paragraphStyle: para,
        ])

        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
        }
    }
}
