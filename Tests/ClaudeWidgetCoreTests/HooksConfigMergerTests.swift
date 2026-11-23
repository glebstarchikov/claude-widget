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

    private func firstHook(_ settings: [String: Any], event: String) -> [String: Any] {
        let hooks = settings["hooks"] as! [String: Any]
        return ((hooks[event] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
    }

    func testPermissionRequestEntryIsSynchronousWith60sTimeout() {
        let merged = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        let hook = firstHook(merged, event: "PermissionRequest")
        XCTAssertNil(hook["async"])
        XCTAssertEqual(hook["timeout"] as? Int, 60)
    }

    func testOtherEntriesStayAsync() {
        let merged = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        for (event, _) in HooksConfigMerger.events where event != "PermissionRequest" {
            let hook = firstHook(merged, event: event)
            XCTAssertEqual(hook["async"] as? Bool, true, event)
            XCTAssertEqual(hook["timeout"] as? Int, 10, event)
        }
    }

    private var oldAsyncSettings: [String: Any] {
        var settings = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        var hooks = settings["hooks"] as! [String: Any]
        hooks["PermissionRequest"] = [[
            "matcher": "*",
            "hooks": [["type": "command", "command": "\"\(binPath)\" PermissionRequest",
                       "async": true, "timeout": 10] as [String: Any]],
        ] as [String: Any]]
        settings["hooks"] = hooks
        return settings
    }

    func testOldAsyncPermissionEntryIsNotInstalled() {
        XCTAssertFalse(HooksConfigMerger.isInstalled(settings: oldAsyncSettings))
    }

    private func settings(permissionHook: [String: Any]) -> [String: Any] {
        var settings = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        var hooks = settings["hooks"] as! [String: Any]
        hooks["PermissionRequest"] = [["matcher": "*", "hooks": [permissionHook]] as [String: Any]]
        settings["hooks"] = hooks
        return settings
    }

    func testSynchronousEntryNeedsATimeoutPastTheDecisionWait() {
        let command = "\"\(binPath)\" PermissionRequest"
        func installed(_ extra: [String: Any]) -> Bool {
            var hook: [String: Any] = ["type": "command", "command": command]
            hook.merge(extra) { _, new in new }
            return HooksConfigMerger.isInstalled(settings: settings(permissionHook: hook))
        }
        for seconds in [31, 60, 90, 120, 600] {
            XCTAssertTrue(installed(["timeout": seconds]), "\(seconds) s outlasts the 30 s decision wait")
        }
        XCTAssertTrue(installed(["timeout": 90, "async": false]))
        XCTAssertFalse(installed([:]), "no timeout")
        XCTAssertFalse(installed(["timeout": 30]), "killed as the 30 s decision wait ends")
        XCTAssertFalse(installed(["timeout": 10]), "killed before the 30 s decision wait ends")
        XCTAssertFalse(installed(["timeout": 0]))
        XCTAssertFalse(installed(["timeout": -60]))
        XCTAssertFalse(installed(["timeout": 45.5]), "not a whole number of seconds")
        XCTAssertFalse(installed(["timeout": "60"]), "a string isn't a timeout")
        XCTAssertFalse(installed(["timeout": true]))
        XCTAssertFalse(installed(["timeout": NSNull()]))
        XCTAssertFalse(installed(["timeout": 60, "async": true]), "async never waits for the answer")
        XCTAssertFalse(installed(["timeout": 120, "async": true]))
    }

    /// As a settings file parses: numbers and booleans both arrive as NSNumber.
    func testParsedTimeoutsReadTheSame() {
        let command = "\"\(binPath)\" PermissionRequest"
        func installed(_ json: String) -> Bool {
            let hook = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            var hookWithCommand = hook
            hookWithCommand["command"] = command
            let parsed = try! JSONSerialization.jsonObject(with: JSONSerialization.data(
                withJSONObject: settings(permissionHook: hookWithCommand))) as! [String: Any]
            return HooksConfigMerger.isInstalled(settings: parsed)
        }
        XCTAssertTrue(installed(#"{"type":"command","timeout":60}"#))
        XCTAssertTrue(installed(#"{"type":"command","timeout":90}"#))
        XCTAssertFalse(installed(#"{"type":"command","timeout":30}"#))
        XCTAssertFalse(installed(#"{"type":"command","timeout":true}"#), "a boolean isn't 1 s")
        XCTAssertFalse(installed(#"{"type":"command","timeout":45.5}"#))
        XCTAssertFalse(installed(#"{"type":"command","timeout":"90"}"#))
        XCTAssertFalse(installed(#"{"type":"command"}"#))
        XCTAssertFalse(installed(#"{"type":"command","timeout":90,"async":true}"#))
    }

    func testTheMergerStillWrites60() {
        let merged = HooksConfigMerger.merge(settings: [:], binaryPath: binPath)
        let entries = (merged["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual((entries?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 60)
    }

    func testEditedTimeoutIsRepairedByMerge() {
        let edited = settings(permissionHook: ["type": "command", "command": "\"\(binPath)\" PermissionRequest", "timeout": 10])
        XCTAssertFalse(HooksConfigMerger.isInstalled(settings: edited))
        XCTAssertTrue(HooksConfigMerger.isInstalled(settings: HooksConfigMerger.merge(settings: edited, binaryPath: binPath)))
    }

    func testMergeReplacesOldAsyncEntryWithoutDuplicating() {
        let merged = HooksConfigMerger.merge(settings: oldAsyncSettings, binaryPath: binPath)
        XCTAssertEqual(hookCommands(merged, event: "PermissionRequest").count, 1)
        XCTAssertNil(firstHook(merged, event: "PermissionRequest")["async"])
        XCTAssertTrue(HooksConfigMerger.isInstalled(settings: merged))
    }

    func testForeignSyncPermissionHookUntouched() {
        let foreign: [String: Any] = ["matcher": "*",
            "hooks": [["type": "command", "command": "other/guard.sh", "timeout": 5] as [String: Any]]]
        let existing: [String: Any] = ["hooks": ["PermissionRequest": [foreign]]]
        func foreignEntry(_ s: [String: Any]) -> [String: Any]? {
            ((s["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?
                .first { !HooksConfigMerger.entryIsOurs($0) }
        }
        func bytes(_ e: [String: Any]?) -> Data? {
            e.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        }
        let expected = bytes(foreign)
        let merged = HooksConfigMerger.merge(settings: existing, binaryPath: binPath)
        XCTAssertEqual(bytes(foreignEntry(merged)), expected)
        XCTAssertEqual(hookCommands(merged, event: "PermissionRequest").count, 2)
        let removed = HooksConfigMerger.remove(settings: merged)
        XCTAssertEqual(bytes(foreignEntry(removed)), expected)
        XCTAssertEqual(hookCommands(removed, event: "PermissionRequest"), ["other/guard.sh"])
    }
}
