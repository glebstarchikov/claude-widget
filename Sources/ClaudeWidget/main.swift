import AppKit
import ClaudeWidgetCore

if CommandLine.arguments.contains("--dump-poses") {
    let out = URL(fileURLWithPath: CommandLine.arguments.last!)
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
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }
    }
    exit(0)
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-icon"),
   CommandLine.arguments.count > flagIndex + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
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
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
        }
    }
    exit(0)
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-dmg-bg"),
   CommandLine.arguments.count > flagIndex + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    // Render into a 2x bitmap but tag it as a 600x400-point image (144 DPI), so
    // Finder maps 1 image-point = 1 window-point AND stays crisp on Retina.
    let w: CGFloat = 600, h: CGFloat = 400
    let scale = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(w) * scale, pixelsHigh: Int(h) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(0) }
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
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// AppDelegate() is @MainActor-isolated; main.swift's top level is a synchronous
// nonisolated context, so the isolated init needs an explicit assertion that
// we're already on the main thread here (true at process entry).
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
