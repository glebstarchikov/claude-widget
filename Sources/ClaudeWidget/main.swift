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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// AppDelegate() is @MainActor-isolated; main.swift's top level is a synchronous
// nonisolated context, so the isolated init needs an explicit assertion that
// we're already on the main thread here (true at process entry).
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
