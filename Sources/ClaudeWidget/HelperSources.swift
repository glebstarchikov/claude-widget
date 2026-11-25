import Foundation
import ClaudeWidgetCore

/// The helpers the app copies out of its bundle with `HelperCopy`, next to the
/// app executable both in `swift build` output and in Claude Widget.app, with
/// their `LaunchStamp`s. main.swift reads the stamps before anything copies, so
/// they describe the bundle the user approved, not one that replaced it later.
enum HelperSources {
    static let hook = directory.appendingPathComponent("claude-widget-hook")
    static let adapter = directory.appendingPathComponent("libMediaRemoteAdapter.dylib")
    static let hookStamp = LaunchStamp(of: hook)
    static let adapterStamp = LaunchStamp(of: adapter)

    private static let directory = Bundle.main.executableURL!.deletingLastPathComponent()
}
