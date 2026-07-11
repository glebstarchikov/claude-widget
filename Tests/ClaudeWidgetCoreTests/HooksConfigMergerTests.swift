import XCTest
@testable import ClaudeWidgetCore

final class HooksConfigMergerTests: XCTestCase {
    let binPath = "$HOME/.claude/claude-widget/bin/claude-widget-hook"

    private func hookCommands(_ settings: [String: Any], event: String) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testMergeIntoEmptySettingsInstallsAllSevenEvents() {
        let merged = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        for (event, _) in HooksConfigMerger.events {
            let commands = hookCommands(merged, event: event)
            XCTAssertEqual(commands.count, 1, event)
            XCTAssertEqual(commands[0], "\"\(binPath)\" \(event)")
        }
        XCTAssertTrue(HooksConfigMerger.isInstalled(settings: merged))
    }

    func testMergePreservesForeignHooksAndOtherKeys() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "superset/notify.sh"]]]]
            ]
        ]
        let merged = HooksConfigMerger.merge(settings: existing, binaryPath: binPath)
        XCTAssertEqual(merged["model"] as? String, "opus")
        let stopCommands = hookCommands(merged, event: "Stop")
        XCTAssertTrue(stopCommands.contains("superset/notify.sh"), "existing hooks preserved")
        XCTAssertTrue(stopCommands.contains("\"\(binPath)\" Stop"))
    }

    func testMergeIsIdempotent() {
        let once = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        let twice = HooksConfigMerger.merge(settings: once, binaryPath: binPath)
        XCTAssertEqual(hookCommands(twice, event: "Stop").count, 1)
    }

    func testMatchersOnlyWhereRequired() {
        let merged = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        let hooks = merged["hooks"] as! [String: Any]
        let pre = (hooks["PreToolUse"] as! [[String: Any]])[0]
        let stop = (hooks["Stop"] as! [[String: Any]])[0]
        XCTAssertEqual(pre["matcher"] as? String, "*")
        XCTAssertNil(stop["matcher"])
    }

    func testMergedEntriesAreAsyncWithTimeout() {
        let merged = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        let hooks = merged["hooks"] as! [String: Any]
        let entry = ((hooks["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(entry["async"] as? Bool, true)
        XCTAssertEqual(entry["timeout"] as? Int, 10)
    }

    func testRemoveStripsOnlyOurEntries() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "superset/notify.sh"]]]]
            ]
        ]
        let merged = HooksConfigMerger.merge(settings: existing, binaryPath: binPath)
        let removed = HooksConfigMerger.remove(settings: merged)
        XCTAssertEqual(hookCommands(removed, event: "Stop"), ["superset/notify.sh"])
        XCTAssertEqual(hookCommands(removed, event: "SessionStart"), [])
        XCTAssertFalse(HooksConfigMerger.isInstalled(settings: removed))
        let hooks = removed["hooks"] as! [String: Any]
        XCTAssertNil(hooks["SessionStart"], "event keys left empty are dropped")
    }
}
