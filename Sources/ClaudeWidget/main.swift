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
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: px * 0.06, dy: px * 0.06),
                                  xRadius: px * 0.22, yRadius: px * 0.22)
            Theme.accentLight.setFill()
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// AppDelegate() is @MainActor-isolated; main.swift's top level is a synchronous
// nonisolated context, so the isolated init needs an explicit assertion that
// we're already on the main thread here (true at process entry).
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
