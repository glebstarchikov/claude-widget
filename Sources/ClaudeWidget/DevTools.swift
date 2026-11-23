import AppKit
import ClaudeWidgetCore
import MediaRemoteAdapter

/// Off-screen asset generation invoked by the build scripts (`bundle.sh`,
/// `dmg.sh`), never at runtime. Kept out of `main.swift` so the app's entry
/// point stays just the runtime wiring.
enum DevTools {
    /// The DMG arrow stroke: the original indigo, independent of the chosen theme.
    private static let arrowStroke = NSColor(hex: 0x4B46F5)
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
        if arguments.contains("--now-playing-check") {
            nowPlayingCheck()
            return true
        }
        return false
    }

    /// Prints where the adapter resolved its dylib and perl script, plus one read of the
    /// current track. A dev tool on demand, so the title is printed here.
    private static func nowPlayingCheck() {
        let controller = MediaController()
        func report(_ label: String, _ path: String?) {
            let found = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            print("\(label): \(path ?? "nil") (\(found ? "found" : "missing"))")
        }
        report("library", controller.libraryPath)
        report("script", controller.perlScriptPath)
        var done = false
        controller.getTrackInfo { info in
            if let title = info?.payload.title {
                print("track: \(title) — \(info?.payload.applicationName ?? "unknown app")")
            } else {
                print("track: none")
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !done { print("track: none") }
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    /// Dumps critter states per theme (working, needs-you dot, asleep, needs-you + hat)
    /// at 18 pt and 72 pt, on a light and a dark menu bar, for eyeballing.
    private static func dumpPoses(to out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let custom = RGB(hex: "#4B46F5")!
        func ns(_ c: RGB) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
        let states: [(String, CritterPose, CGFloat, Bool, Bool)] = [
            ("working", .walkA, 1.0, false, false),
            ("needsyou", .idle, 1.0, false, true),
            ("asleep", .asleep, 0.45, false, false),
            ("needsyou-hat", .idle, 1.0, true, true),
            ("working-hat", .walkA, 1.0, true, false),
            ("asleep-hat", .asleep, 0.45, true, false),
            ("ready-hat", .idle, 0.70, true, false),
        ]
        // Montage columns, in order (18 pt at 2x = 36 px, then enlarged 4x without smoothing).
        let montageColumns = ["working", "needsyou", "asleep", "working-hat", "needsyou-hat", "asleep-hat"]
        let bars: [(String, RGB, Bool)] = [("light", ThemePalette.lightBar, false), ("dark", ThemePalette.darkBar, true)]
        for theme in [ThemeID.claude, .system, .indigo] {
            let pair = ThemePalette.pair(for: theme, custom: custom)
            for (barName, bar, dark) in bars {
                let themed = ns(dark ? pair.dark : pair.light)
                let faint = dark ? Theme.faintDark : Theme.faintLight
                for (name, pose, opacity, hat, badge) in states {
                    let color = pose == .asleep ? faint : themed
                    for size in [18, 36, 72] as [CGFloat] {
                        let critter = CritterRenderer.image(pose: pose, color: color, opacity: opacity,
                                                            pointSize: size, hat: hat, badge: badge)
                        let canvas = NSImage(size: NSSize(width: size + 8, height: size + 8), flipped: true) { rect in
                            ns(bar).setFill()
                            rect.fill()
                            critter.draw(in: NSRect(x: 4, y: 4, width: size, height: size))
                            return true
                        }
                        writePNG(canvas, to: out.appendingPathComponent("\(theme.rawValue)-\(name)-\(barName)-\(Int(size)).png"))
                    }
                }
                // Montage at 18 pt 2x.
                let tile: CGFloat = 44, zoom: CGFloat = 4
                let montage = NSImage(size: NSSize(width: tile * CGFloat(montageColumns.count), height: tile), flipped: true) { rect in
                    ns(bar).setFill()
                    rect.fill()
                    for (i, column) in montageColumns.enumerated() {
                        guard let (_, pose, opacity, hat, badge) = states.first(where: { $0.0 == column }) else { continue }
                        let critter = CritterRenderer.image(pose: pose, color: pose == .asleep ? faint : themed, opacity: opacity,
                                                            pointSize: 36, hat: hat, badge: badge)
                        critter.draw(in: NSRect(x: CGFloat(i) * tile + 4, y: 4, width: 36, height: 36))
                    }
                    return true
                }
                let big = NSImage(size: NSSize(width: montage.size.width * zoom, height: tile * zoom), flipped: true) { rect in
                    NSGraphicsContext.current?.imageInterpolation = .none
                    montage.draw(in: rect)
                    return true
                }
                writePNG(big, to: out.appendingPathComponent("montage-\(theme.rawValue)-\(barName)-18pt-2x.png"))
            }
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
        Self.arrowStroke.setStroke()
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
