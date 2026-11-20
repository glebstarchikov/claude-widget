// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "claude-widget",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "ClaudeWidgetCore"),
        .executableTarget(
            name: "claude-widget-hook",
            dependencies: ["ClaudeWidgetCore"],
            path: "Sources/ClaudeWidgetHook"
        ),
        .executableTarget(
            name: "ClaudeWidget",
            dependencies: ["ClaudeWidgetCore"]
        ),
        .testTarget(
            name: "ClaudeWidgetCoreTests",
            dependencies: ["ClaudeWidgetCore"]
        ),
    ]
)
