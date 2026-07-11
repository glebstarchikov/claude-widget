# Claude Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app where the Claude Code critter mirrors live Claude Code session state (walking / orange "needs you" / asleep), with a notch peek panel and a session popover.

**Architecture:** Claude Code hooks (all `async`) invoke a tiny compiled `claude-widget-hook` CLI that writes one JSON state file per session under `~/.claude/claude-widget/state/`. The app watches that directory with a DispatchSource, derives an aggregate state, and drives three surfaces: the animated status item, a notch peek `NSPanel`, and a SwiftUI popover. All logic lives in a testable `ClaudeWidgetCore` library.

**Tech Stack:** Swift (SwiftPM only, no Xcode project, no third-party dependencies), AppKit + SwiftUI, XCTest. Spec: `docs/superpowers/specs/2026-07-10-claude-widget-design.md`.

## Global Constraints

- Platform floor: macOS 14 (`platforms: [.macOS(.v14)]`); swift-tools-version 5.10; zero external packages.
- Colors (exact): accent light `#4b46f5`, accent dark `#8a86ff`, faint light `#6f6e79`, faint dark `#908f99`, Claude orange `#D97757` (both appearances), notch panel bg `#1c1b1f`, panel border `#2a292e`, panel fg `#ececea`.
- State opacities: asleep 45 %, ready/waiting 70 %, working/needsYou 100 %.
- Constants (single source `WidgetConstants`): walk frame 450 ms, pulse 1.2 s, blink 4–7 s, finished-peek threshold 60 s, finished-peek auto-hide 5 s, staleness 4 h, GC interval 1 h, peek slide 240 ms.
- Every hook entry: `"async": true, "timeout": 10`; command string `"$HOME/.claude/claude-widget/bin/claude-widget-hook" <Event>`.
- All looping animation honors `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- UI copy: sentence case, no em-dashes, no exclamation marks. Mono font = "Geist Mono" if installed, else SF Mono.
- The hook binary must never disturb Claude: exit 0 on any malformed input.
- Commits: end every commit message with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Package scaffold, constants, session model

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeWidgetCore/WidgetConstants.swift`
- Create: `Sources/ClaudeWidgetCore/Session.swift`
- Create: `Sources/ClaudeWidgetHook/main.swift` (placeholder so the package builds)
- Create: `Sources/ClaudeWidget/main.swift` (placeholder so the package builds)
- Test: `Tests/ClaudeWidgetCoreTests/SessionTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `WidgetConstants` (all constants + `stateDir`/`binDir`/`hookBinary`/`claudeSettings: URL`), `Session` (Codable struct: `sessionId/state/cwd/message/workingSince/updatedAt`, computed `projectName`), `SessionState` enum (`.ready/.working/.needsYou/.waiting`), `AggregateState` enum (`.asleep/.ready/.waiting/.working/.needsYou`).

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "claude-widget",
    platforms: [.macOS(.v14)],
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
```

- [ ] **Step 2: Write WidgetConstants.swift**

```swift
import Foundation

public enum WidgetConstants {
    public static let walkFrameDuration: TimeInterval = 0.45
    public static let pulsePeriod: TimeInterval = 1.2
    public static let blinkIntervalRange: ClosedRange<TimeInterval> = 4...7
    public static let finishedPeekThreshold: TimeInterval = 60
    public static let finishedPeekAutoHide: TimeInterval = 5
    public static let staleAfter: TimeInterval = 4 * 3600
    public static let gcInterval: TimeInterval = 3600
    public static let peekSlideDuration: TimeInterval = 0.24

    public static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/claude-widget", isDirectory: true)
    }
    public static var stateDir: URL {
        baseDir.appendingPathComponent("state", isDirectory: true)
    }
    public static var binDir: URL {
        baseDir.appendingPathComponent("bin", isDirectory: true)
    }
    public static var hookBinary: URL {
        binDir.appendingPathComponent("claude-widget-hook")
    }
    public static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
}
```

- [ ] **Step 3: Write Session.swift**

```swift
import Foundation

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case ready, working, needsYou, waiting
}

public struct Session: Codable, Equatable, Sendable {
    public var sessionId: String
    public var state: SessionState
    public var cwd: String
    public var message: String?
    public var workingSince: Double?
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state, cwd, message
        case workingSince = "working_since"
        case updatedAt = "updated_at"
    }

    public init(sessionId: String, state: SessionState, cwd: String,
                message: String? = nil, workingSince: Double? = nil, updatedAt: Double) {
        self.sessionId = sessionId
        self.state = state
        self.cwd = cwd
        self.message = message
        self.workingSince = workingSince
        self.updatedAt = updatedAt
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }
}

public enum AggregateState: Equatable, Sendable {
    case asleep, ready, waiting, working, needsYou
}
```

- [ ] **Step 4: Write placeholder executables** (replaced in Tasks 7 and 8)

`Sources/ClaudeWidgetHook/main.swift`:
```swift
import Foundation
exit(0)
```

`Sources/ClaudeWidget/main.swift`:
```swift
import Foundation
print("claude-widget app placeholder")
```

- [ ] **Step 5: Write the failing test**

`Tests/ClaudeWidgetCoreTests/SessionTests.swift`:
```swift
import XCTest
@testable import ClaudeWidgetCore

final class SessionTests: XCTestCase {
    func testCodableRoundTripWithSnakeCaseKeys() throws {
        let session = Session(sessionId: "abc", state: .needsYou, cwd: "/Users/gleb/claude-widget",
                              message: "Bash", workingSince: 100.5, updatedAt: 200.0)
        let data = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["session_id"] as? String, "abc")
        XCTAssertEqual(json["working_since"] as? Double, 100.5)
        XCTAssertEqual(json["state"] as? String, "needsYou")
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    func testProjectName() {
        let session = Session(sessionId: "a", state: .ready, cwd: "/Users/gleb/my-project", updatedAt: 0)
        XCTAssertEqual(session.projectName, "my-project")
    }
}
```

- [ ] **Step 6: Run tests, verify they pass** (model code was written in Step 3, so this validates the scaffold compiles and tests run)

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed` with 2 tests.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: package scaffold, constants, session model"
```

---

### Task 2: EventMapper (hook payload → session update)

**Files:**
- Create: `Sources/ClaudeWidgetCore/EventMapper.swift`
- Test: `Tests/ClaudeWidgetCoreTests/EventMapperTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionState` from Task 1.
- Produces: `HookPayload` (`init?(json: Data)`, fields `sessionId/cwd/message/notificationType/toolName`), `SessionUpdate` enum (`.write(Session)/.remove(sessionId: String)/.ignore`), `EventMapper.map(event: String, payload: HookPayload, previous: Session?, now: Double) -> SessionUpdate`.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeWidgetCoreTests/EventMapperTests.swift`:
```swift
import XCTest
@testable import ClaudeWidgetCore

final class EventMapperTests: XCTestCase {
    private func payload(_ extra: String = "") -> HookPayload {
        let json = #"{"session_id":"s1","cwd":"/tmp/proj"\#(extra)}"#.data(using: .utf8)!
        return HookPayload(json: json)!
    }

    func testPayloadRejectsMissingSessionId() {
        XCTAssertNil(HookPayload(json: #"{"cwd":"/tmp"}"#.data(using: .utf8)!))
        XCTAssertNil(HookPayload(json: "not json".data(using: .utf8)!))
    }

    func testSessionStartWritesReadyAndClearsWorkingSince() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 50, updatedAt: 60)
        let update = EventMapper.map(event: "SessionStart", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .ready)
        XCTAssertNil(s.workingSince)
        XCTAssertEqual(s.updatedAt, 100)
    }

    func testPromptSubmitStampsWorkingSinceOnNewStretch() {
        let prev = Session(sessionId: "s1", state: .waiting, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        let update = EventMapper.map(event: "UserPromptSubmit", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .working)
        XCTAssertEqual(s.workingSince, 100, "new working stretch re-stamps")
    }

    func testPreToolUsePreservesWorkingSinceWithinStretch() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        let update = EventMapper.map(event: "PreToolUse", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.workingSince, 10)
    }

    func testPermissionRequestMapsToNeedsYouWithToolNameAndCarriesWorkingSince() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        let update = EventMapper.map(event: "PermissionRequest", payload: payload(#","tool_name":"Bash"#), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .needsYou)
        XCTAssertEqual(s.message, "Bash")
        XCTAssertEqual(s.workingSince, 10, "carried so the app can read it at transitions")
    }

    func testNotificationMapsToNeedsYouWithMessage() {
        let update = EventMapper.map(event: "Notification", payload: payload(#","message":"Claude is waiting for your input"#), previous: nil, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .needsYou)
        XCTAssertEqual(s.message, "Claude is waiting for your input")
    }

    func testStopMapsToWaitingAndCarriesWorkingSince() {
        let prev = Session(sessionId: "s1", state: .working, cwd: "/tmp/proj", workingSince: 10, updatedAt: 20)
        let update = EventMapper.map(event: "Stop", payload: payload(), previous: prev, now: 100)
        guard case .write(let s) = update else { return XCTFail("expected write") }
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.workingSince, 10)
    }

    func testSessionEndRemoves() {
        XCTAssertEqual(EventMapper.map(event: "SessionEnd", payload: payload(), previous: nil, now: 100),
                       .remove(sessionId: "s1"))
    }

    func testUnknownEventIgnored() {
        XCTAssertEqual(EventMapper.map(event: "PostToolBatch", payload: payload(), previous: nil, now: 100), .ignore)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EventMapperTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'HookPayload' in scope`.

- [ ] **Step 3: Write EventMapper.swift**

```swift
import Foundation

public struct HookPayload: Sendable {
    public var sessionId: String
    public var cwd: String
    public var message: String?
    public var notificationType: String?
    public var toolName: String?

    public init?(json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = obj["session_id"] as? String, !id.isEmpty else { return nil }
        sessionId = id
        cwd = obj["cwd"] as? String ?? ""
        message = obj["message"] as? String
        notificationType = obj["notification_type"] as? String
        toolName = obj["tool_name"] as? String
    }
}

public enum SessionUpdate: Equatable, Sendable {
    case write(Session)
    case remove(sessionId: String)
    case ignore
}

public enum EventMapper {
    public static func map(event: String, payload: HookPayload, previous: Session?, now: Double) -> SessionUpdate {
        func session(_ state: SessionState, message: String? = nil) -> Session {
            var workingSince = previous?.workingSince
            if state == .working && previous?.state != .working {
                workingSince = now
            }
            return Session(sessionId: payload.sessionId, state: state, cwd: payload.cwd,
                           message: message, workingSince: workingSince, updatedAt: now)
        }
        switch event {
        case "SessionStart":
            return .write(Session(sessionId: payload.sessionId, state: .ready, cwd: payload.cwd,
                                  message: nil, workingSince: nil, updatedAt: now))
        case "UserPromptSubmit", "PreToolUse":
            return .write(session(.working))
        case "PermissionRequest":
            return .write(session(.needsYou, message: payload.toolName))
        case "Notification":
            return .write(session(.needsYou, message: payload.message))
        case "Stop":
            return .write(session(.waiting))
        case "SessionEnd":
            return .remove(sessionId: payload.sessionId)
        default:
            return .ignore
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EventMapperTests 2>&1 | tail -3`
Expected: `passed` with 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeWidgetCore/EventMapper.swift Tests/ClaudeWidgetCoreTests/EventMapperTests.swift
git commit -m "feat: map hook events to session state updates"
```

---

### Task 3: StateStore (atomic file IO, corrupt-file cleanup, staleness GC)

**Files:**
- Create: `Sources/ClaudeWidgetCore/StateStore.swift`
- Test: `Tests/ClaudeWidgetCoreTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionUpdate`, `WidgetConstants.staleAfter`.
- Produces: `StateStore(directory: URL)` with `apply(_ update: SessionUpdate) throws`, `read(sessionId: String) -> Session?`, `loadAll(now: Double) -> [Session]` (sorted by `updatedAt` descending; deletes corrupt and stale files as it reads), `fileURL(for sessionId: String) -> URL`.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeWidgetCoreTests/StateStoreTests.swift`:
```swift
import XCTest
@testable import ClaudeWidgetCore

final class StateStoreTests: XCTestCase {
    var dir: URL!
    var store: StateStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-tests-\(UUID().uuidString)", isDirectory: true)
        store = StateStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func session(_ id: String, state: SessionState = .working, updatedAt: Double) -> Session {
        Session(sessionId: id, state: state, cwd: "/tmp/proj", updatedAt: updatedAt)
    }

    func testWriteThenReadRoundTrip() throws {
        let s = session("s1", updatedAt: 100)
        try store.apply(.write(s))
        XCTAssertEqual(store.read(sessionId: "s1"), s)
    }

    func testRemoveDeletesFile() throws {
        try store.apply(.write(session("s1", updatedAt: 100)))
        try store.apply(.remove(sessionId: "s1"))
        XCTAssertNil(store.read(sessionId: "s1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "s1").path))
    }

    func testRemoveNonexistentDoesNotThrow() {
        XCTAssertNoThrow(try store.apply(.remove(sessionId: "ghost")))
    }

    func testIgnoreIsNoOp() throws {
        try store.apply(.ignore)
        XCTAssertEqual(store.loadAll(now: 0), [])
    }

    func testLoadAllSortsByUpdatedAtDescending() throws {
        try store.apply(.write(session("old", updatedAt: 100)))
        try store.apply(.write(session("new", updatedAt: 200)))
        XCTAssertEqual(store.loadAll(now: 300).map(\.sessionId), ["new", "old"])
    }

    func testLoadAllDeletesCorruptFiles() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("bad.json")
        try "{ not json".data(using: .utf8)!.write(to: bad)
        XCTAssertEqual(store.loadAll(now: 0), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
    }

    func testLoadAllGarbageCollectsStaleSessions() throws {
        let now: Double = 1_000_000
        try store.apply(.write(session("fresh", updatedAt: now - 60)))
        try store.apply(.write(session("stale", updatedAt: now - WidgetConstants.staleAfter - 1)))
        XCTAssertEqual(store.loadAll(now: now).map(\.sessionId), ["fresh"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "stale").path))
    }

    func testLoadAllOnMissingDirectoryReturnsEmpty() {
        XCTAssertEqual(store.loadAll(now: 0), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StateStoreTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'StateStore' in scope`.

- [ ] **Step 3: Write StateStore.swift**

```swift
import Foundation

public struct StateStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent("\(sessionId).json")
    }

    public func apply(_ update: SessionUpdate) throws {
        switch update {
        case .ignore:
            return
        case .remove(let id):
            try? FileManager.default.removeItem(at: fileURL(for: id))
        case .write(let session):
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            let tmp = directory.appendingPathComponent(".\(session.sessionId).tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(fileURL(for: session.sessionId), withItemAt: tmp)
        }
    }

    public func read(sessionId: String) -> Session? {
        guard let data = try? Data(contentsOf: fileURL(for: sessionId)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func loadAll(now: Double) -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var sessions: [Session] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(Session.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if now - session.updatedAt > WidgetConstants.staleAfter {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            sessions.append(session)
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StateStoreTests 2>&1 | tail -3`
Expected: `passed` with 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeWidgetCore/StateStore.swift Tests/ClaudeWidgetCoreTests/StateStoreTests.swift
git commit -m "feat: atomic session state file store with GC"
```

---

### Task 4: Aggregator (icon state priority + peek event detection)

**Files:**
- Create: `Sources/ClaudeWidgetCore/Aggregator.swift`
- Test: `Tests/ClaudeWidgetCoreTests/AggregatorTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionState`, `AggregateState`, `WidgetConstants.finishedPeekThreshold`.
- Produces: `PeekEvent` enum (`.needsYou(Session)` / `.finished(Session, duration: TimeInterval)`), `Aggregator.aggregate(_ sessions: [Session]) -> AggregateState`, `Aggregator.peekEvents(old: [Session], new: [Session], now: Double) -> [PeekEvent]`.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeWidgetCoreTests/AggregatorTests.swift`:
```swift
import XCTest
@testable import ClaudeWidgetCore

final class AggregatorTests: XCTestCase {
    private func session(_ id: String, _ state: SessionState, workingSince: Double? = nil) -> Session {
        Session(sessionId: id, state: state, cwd: "/tmp/proj", workingSince: workingSince, updatedAt: 0)
    }

    func testAggregatePriority() {
        XCTAssertEqual(Aggregator.aggregate([]), .asleep)
        XCTAssertEqual(Aggregator.aggregate([session("a", .ready)]), .ready)
        XCTAssertEqual(Aggregator.aggregate([session("a", .ready), session("b", .waiting)]), .waiting)
        XCTAssertEqual(Aggregator.aggregate([session("a", .waiting), session("b", .working)]), .working)
        XCTAssertEqual(Aggregator.aggregate([session("a", .working), session("b", .needsYou)]), .needsYou)
    }

    func testNeedsYouPeekFiresOnlyOnTransition() {
        let before = [session("a", .working)]
        let after = [session("a", .needsYou)]
        XCTAssertEqual(Aggregator.peekEvents(old: before, new: after, now: 100), [.needsYou(after[0])])
        XCTAssertEqual(Aggregator.peekEvents(old: after, new: after, now: 100), [], "no repeat while state persists")
    }

    func testNeedsYouPeekFiresForBrandNewSession() {
        let after = [session("a", .needsYou)]
        XCTAssertEqual(Aggregator.peekEvents(old: [], new: after, now: 100), [.needsYou(after[0])])
    }

    func testFinishedPeekRequiresLongWorkingStretch() {
        let now: Double = 1000
        let longRun = [session("a", .working, workingSince: now - 61)]
        let shortRun = [session("a", .working, workingSince: now - 59)]
        let stopped = [session("a", .waiting, workingSince: now - 61)]

        XCTAssertEqual(Aggregator.peekEvents(old: longRun, new: stopped, now: now),
                       [.finished(stopped[0], duration: 61)])
        XCTAssertEqual(Aggregator.peekEvents(old: shortRun, new: stopped, now: now), [],
                       "under 60 s stays quiet")
        XCTAssertEqual(Aggregator.peekEvents(old: stopped, new: stopped, now: now), [],
                       "waiting to waiting fires nothing")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AggregatorTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'Aggregator' in scope`.

- [ ] **Step 3: Write Aggregator.swift**

```swift
import Foundation

public enum PeekEvent: Equatable, Sendable {
    case needsYou(Session)
    case finished(Session, duration: TimeInterval)
}

public enum Aggregator {
    public static func aggregate(_ sessions: [Session]) -> AggregateState {
        if sessions.isEmpty { return .asleep }
        if sessions.contains(where: { $0.state == .needsYou }) { return .needsYou }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        if sessions.contains(where: { $0.state == .waiting }) { return .waiting }
        return .ready
    }

    public static func peekEvents(old: [Session], new: [Session], now: Double) -> [PeekEvent] {
        let oldById = Dictionary(old.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [PeekEvent] = []
        for session in new {
            let previous = oldById[session.sessionId]
            if session.state == .needsYou && previous?.state != .needsYou {
                events.append(.needsYou(session))
            }
            if session.state == .waiting, let prev = previous, prev.state == .working,
               let since = prev.workingSince, now - since >= WidgetConstants.finishedPeekThreshold {
                events.append(.finished(session, duration: now - since))
            }
        }
        return events
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AggregatorTests 2>&1 | tail -3`
Expected: `passed` with 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeWidgetCore/Aggregator.swift Tests/ClaudeWidgetCoreTests/AggregatorTests.swift
git commit -m "feat: aggregate state priority and peek detection"
```

---

### Task 5: CritterGeometry (official logo rects + poses)

**Files:**
- Create: `Sources/ClaudeWidgetCore/CritterGeometry.swift`
- Test: `Tests/ClaudeWidgetCoreTests/CritterGeometryTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `CritterPose` enum (`.idle/.walkA/.walkB/.blink/.asleep`), `CritterGeometry.canvas: CGSize` (24×24), `CritterGeometry.bodyRects(pose:) -> [CGRect]` (7 rects: body, 2 nubs, 4 legs), `CritterGeometry.eyeCutouts(pose:) -> [CGRect]`. Coordinates are SVG space (y grows downward); the renderer flips.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeWidgetCoreTests/CritterGeometryTests.swift`:
```swift
import XCTest
@testable import ClaudeWidgetCore

final class CritterGeometryTests: XCTestCase {
    func testIdleHasSevenBodyRectsWithOfficialCoordinates() {
        let rects = CritterGeometry.bodyRects(pose: .idle)
        XCTAssertEqual(rects.count, 7)
        XCTAssertEqual(rects[0], CGRect(x: 3, y: 5, width: 17.998, height: 12.079), "body")
        XCTAssertEqual(rects[1], CGRect(x: 0, y: 10.95, width: 3, height: 3.1), "left nub")
        XCTAssertEqual(rects[2], CGRect(x: 21, y: 10.949, width: 3, height: 3.102), "right nub")
        XCTAssertEqual(rects[3], CGRect(x: 4.487, y: 17.079, width: 1.513, height: 2.921), "leg 1")
    }

    func testWalkALiftsLegsOneAndThree() {
        let rects = CritterGeometry.bodyRects(pose: .walkA)
        let full = 2.921, lifted = 2.921 * 0.6
        XCTAssertEqual(rects[3].height, lifted, accuracy: 0.001)
        XCTAssertEqual(rects[4].height, full, accuracy: 0.001)
        XCTAssertEqual(rects[5].height, lifted, accuracy: 0.001)
        XCTAssertEqual(rects[6].height, full, accuracy: 0.001)
        XCTAssertEqual(rects[3].minY, 17.079, "top-anchored: feet lift, hip stays")
    }

    func testWalkBLiftsLegsTwoAndFour() {
        let rects = CritterGeometry.bodyRects(pose: .walkB)
        XCTAssertEqual(rects[3].height, 2.921, accuracy: 0.001)
        XCTAssertEqual(rects[4].height, 2.921 * 0.6, accuracy: 0.001)
    }

    func testEyes() {
        let open = CritterGeometry.eyeCutouts(pose: .idle)
        XCTAssertEqual(open[0], CGRect(x: 6, y: 8.102, width: 1.488, height: 2.847))
        XCTAssertEqual(open[1], CGRect(x: 16.51, y: 8.102, width: 1.49, height: 2.847))

        XCTAssertTrue(CritterGeometry.eyeCutouts(pose: .blink).isEmpty)

        let asleep = CritterGeometry.eyeCutouts(pose: .asleep)
        XCTAssertEqual(asleep[0].height, 1.05, accuracy: 0.001)
        XCTAssertEqual(asleep[0].maxY, 8.102 + 2.847, accuracy: 0.001, "lid closes from the top, slit stays at the bottom")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CritterGeometryTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'CritterGeometry' in scope`.

- [ ] **Step 3: Write CritterGeometry.swift**

```swift
import Foundation
import CoreGraphics

public enum CritterPose: Equatable, Sendable {
    case idle, walkA, walkB, blink, asleep
}

public enum CritterGeometry {
    public static let canvas = CGSize(width: 24, height: 24)

    static let body = CGRect(x: 3, y: 5, width: 17.998, height: 12.079)
    static let leftNub = CGRect(x: 0, y: 10.95, width: 3, height: 3.1)
    static let rightNub = CGRect(x: 21, y: 10.949, width: 3, height: 3.102)
    static let legs = [
        CGRect(x: 4.487, y: 17.079, width: 1.513, height: 2.921),
        CGRect(x: 7.488, y: 17.079, width: 1.512, height: 2.921),
        CGRect(x: 15, y: 17.079, width: 1.513, height: 2.921),
        CGRect(x: 18, y: 17.079, width: 1.513, height: 2.921),
    ]
    static let eyes = [
        CGRect(x: 6, y: 8.102, width: 1.488, height: 2.847),
        CGRect(x: 16.51, y: 8.102, width: 1.49, height: 2.847),
    ]

    public static func bodyRects(pose: CritterPose) -> [CGRect] {
        var rects = [body, leftNub, rightNub]
        for (index, leg) in legs.enumerated() {
            let lifted = (pose == .walkA && (index == 0 || index == 2))
                      || (pose == .walkB && (index == 1 || index == 3))
            var rect = leg
            if lifted { rect.size.height *= 0.6 }
            rects.append(rect)
        }
        return rects
    }

    public static func eyeCutouts(pose: CritterPose) -> [CGRect] {
        switch pose {
        case .blink:
            return []
        case .asleep:
            return eyes.map { CGRect(x: $0.minX, y: $0.maxY - 1.05, width: $0.width, height: 1.05) }
        default:
            return eyes
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CritterGeometryTests 2>&1 | tail -3`
Expected: `passed` with 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeWidgetCore/CritterGeometry.swift Tests/ClaudeWidgetCoreTests/CritterGeometryTests.swift
git commit -m "feat: critter geometry from official logo path with poses"
```

---

### Task 6: HooksConfigMerger (settings.json transform, pure logic)

**Files:**
- Create: `Sources/ClaudeWidgetCore/HooksConfigMerger.swift`
- Test: `Tests/ClaudeWidgetCoreTests/HooksConfigMergerTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `HooksConfigMerger.merge(settings: [String: Any], binaryPath: String) -> [String: Any]`, `remove(settings: [String: Any]) -> [String: Any]`, `isInstalled(settings: [String: Any]) -> Bool`, `HooksConfigMerger.events: [(name: String, matcher: String?)]` (the 7 events; `PreToolUse` and `PermissionRequest` get matcher `"*"`), `markerSubstring = "claude-widget-hook"`.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeWidgetCoreTests/HooksConfigMergerTests.swift`:
```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HooksConfigMergerTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'HooksConfigMerger' in scope`.

- [ ] **Step 3: Write HooksConfigMerger.swift**

```swift
import Foundation

public enum HooksConfigMerger {
    public static let markerSubstring = "claude-widget-hook"

    public static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "*"),
        ("PermissionRequest", "*"),
        ("Notification", nil),
        ("Stop", nil),
        ("SessionEnd", nil),
    ]

    static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        let commands = (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        return commands.contains { $0.contains(markerSubstring) }
    }

    static func ourEntry(matcher: String?, binaryPath: String, event: String) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "\"\(binaryPath)\" \(event)",
                "async": true,
                "timeout": 10,
            ] as [String: Any]]
        ]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    public static func merge(settings: [String: Any], binaryPath: String) -> [String: Any] {
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, matcher) in events {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !entryIsOurs($0) }
            entries.append(ourEntry(matcher: matcher, binaryPath: binaryPath, event: event))
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    public static func remove(settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return result }
        for (event, _) in events {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryIsOurs($0) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        result["hooks"] = hooks
        return result
    }

    public static func isInstalled(settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event, _ in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: entryIsOurs)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HooksConfigMergerTests 2>&1 | tail -3`
Expected: `passed` with 6 tests.

- [ ] **Step 5: Run the whole suite and commit**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass.

```bash
git add Sources/ClaudeWidgetCore/HooksConfigMerger.swift Tests/ClaudeWidgetCoreTests/HooksConfigMergerTests.swift
git commit -m "feat: additive idempotent hooks config merge"
```

---

### Task 7: Hook executable + simulate.sh

**Files:**
- Modify: `Sources/ClaudeWidgetHook/main.swift` (replace placeholder)
- Create: `scripts/simulate.sh`

**Interfaces:**
- Consumes: `HookPayload`, `EventMapper`, `StateStore`, `WidgetConstants` from Core.
- Produces: the `claude-widget-hook` binary (usage: `claude-widget-hook <EventName>` with hook JSON on stdin) and `scripts/simulate.sh [finished]` which replays a session through the real binary against the real state dir.

- [ ] **Step 1: Replace the hook main.swift**

```swift
import Foundation
import ClaudeWidgetCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(0) }
let event = arguments[1]

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = HookPayload(json: input) else { exit(0) }

let store = StateStore(directory: WidgetConstants.stateDir)
let previous = store.read(sessionId: payload.sessionId)
let update = EventMapper.map(event: event, payload: payload, previous: previous,
                             now: Date().timeIntervalSince1970)
try? store.apply(update)
exit(0)
```

- [ ] **Step 2: Build and verify the binary end to end**

```bash
swift build
echo '{"session_id":"manual-test","cwd":"/tmp/demo"}' | .build/debug/claude-widget-hook UserPromptSubmit
cat ~/.claude/claude-widget/state/manual-test.json
```
Expected: JSON containing `"state":"working"`, `"working_since"` set, `"cwd":"\/tmp\/demo"` (or unescaped `/tmp/demo`).

```bash
echo '{"session_id":"manual-test","cwd":"/tmp/demo"}' | .build/debug/claude-widget-hook SessionEnd
ls ~/.claude/claude-widget/state/
```
Expected: `manual-test.json` is gone.

```bash
echo 'garbage' | .build/debug/claude-widget-hook Stop; echo "exit: $?"
```
Expected: `exit: 0` (malformed input never fails).

- [ ] **Step 3: Write scripts/simulate.sh**

```bash
#!/bin/bash
# Replays a fake Claude Code session through the real hook binary.
# Usage: scripts/simulate.sh            full lifecycle (start → work → permission → work → stop → end)
#        scripts/simulate.sh finished   long-task Stop transition (tests the "Finished" peek)
set -euo pipefail
cd "$(dirname "$0")/.."
HOOK=".build/debug/claude-widget-hook"
[ -x "$HOOK" ] || { echo "build first: swift build"; exit 1; }
STATE_DIR="$HOME/.claude/claude-widget/state"
SID="sim-$$"
CWD="$HOME/demo-project"

fire() { # fire <event> <extra-json-fields> <sleep-after>
  echo "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"$2}" | "$HOOK" "$1"
  echo "→ $1"
  sleep "$3"
}

if [ "${1:-}" = "finished" ]; then
  mkdir -p "$STATE_DIR"
  NOW=$(date +%s)
  SINCE=$((NOW - 120))
  cat > "$STATE_DIR/$SID.json" <<EOF
{"session_id":"$SID","state":"working","cwd":"$CWD","working_since":$SINCE,"updated_at":$NOW}
EOF
  echo "→ crafted 120 s working session"
  sleep 2
  fire Stop "" 6
  fire SessionEnd "" 0
  echo "done: you should have seen the Finished peek"
  exit 0
fi

fire SessionStart "" 2
fire UserPromptSubmit "" 4
fire PreToolUse ',"tool_name":"Bash"' 3
fire PermissionRequest ',"tool_name":"Bash"' 6
fire PreToolUse ',"tool_name":"Bash"' 4
fire Stop "" 5
fire SessionEnd "" 0
echo "done"
```

- [ ] **Step 4: Verify simulate.sh writes and cleans state**

```bash
chmod +x scripts/simulate.sh
scripts/simulate.sh & sleep 6 && cat ~/.claude/claude-widget/state/sim-*.json; wait
ls ~/.claude/claude-widget/state/
```
Expected: mid-run a `sim-*.json` exists (state `working` or `needsYou` depending on timing); after `wait`, the directory has no `sim-*` files.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeWidgetHook/main.swift scripts/simulate.sh
git commit -m "feat: hook CLI writing session state, plus lifecycle simulator"
```

---

### Task 8: App skeleton — SessionMonitor + AppDelegate with placeholder icon

**Files:**
- Modify: `Sources/ClaudeWidget/main.swift` (replace placeholder)
- Create: `Sources/ClaudeWidget/AppDelegate.swift`
- Create: `Sources/ClaudeWidget/SessionMonitor.swift`

**Interfaces:**
- Consumes: `StateStore`, `Aggregator`, `PeekEvent`, `Session`, `WidgetConstants` from Core.
- Produces: `SessionMonitor` (`start()`, `reload()`, `sessions: [Session]`, `onChange: (([Session], [Session], [PeekEvent]) -> Void)?` called with (old, new, peeks) on the main queue), `AppDelegate` (owns the status item; later tasks extend it). App runs via `swift run ClaudeWidget` showing a placeholder menu bar icon.

- [ ] **Step 1: Write SessionMonitor.swift**

```swift
import Foundation
import ClaudeWidgetCore

@MainActor
final class SessionMonitor {
    private let store = StateStore(directory: WidgetConstants.stateDir)
    private var source: DispatchSourceFileSystemObject?
    private var directoryDescriptor: CInt = -1
    private var debounce: DispatchWorkItem?
    private var gcTimer: Timer?

    private(set) var sessions: [Session] = []
    var onChange: (([Session], [Session], [PeekEvent]) -> Void)?

    func start() {
        try? FileManager.default.createDirectory(at: WidgetConstants.stateDir,
                                                 withIntermediateDirectories: true)
        directoryDescriptor = open(WidgetConstants.stateDir.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { [directoryDescriptor] in close(directoryDescriptor) }
        source.resume()
        self.source = source

        gcTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.gcInterval,
                                       repeats: true) { _ in
            Task { @MainActor in self.reload() }
        }
        reload()
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reload() {
        let now = Date().timeIntervalSince1970
        let new = store.loadAll(now: now)
        let old = sessions
        sessions = new
        let peeks = Aggregator.peekEvents(old: old, new: new, now: now)
        onChange?(old, new, peeks)
    }
}
```

- [ ] **Step 2: Write AppDelegate.swift** (placeholder icon; the critter arrives in Task 10)

```swift
import AppKit
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notchAlertsEnabled": true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.dashed",
                                           accessibilityDescription: "Claude Widget")

        monitor = SessionMonitor()
        monitor.onChange = { old, new, peeks in
            let aggregate = Aggregator.aggregate(new)
            NSLog("claude-widget: \(new.count) session(s), aggregate=\(aggregate), peeks=\(peeks.count)")
        }
        monitor.start()
    }
}
```

- [ ] **Step 3: Replace app main.swift**

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 4: Verify the skeleton live**

```bash
swift build && .build/debug/ClaudeWidget & APP_PID=$!
sleep 2
scripts/simulate.sh
sleep 1
kill $APP_PID
```
Expected: a dashed-circle icon appears in the menu bar for the duration; the app's stderr shows lines like `claude-widget: 1 session(s), aggregate=working, peeks=0` changing as the simulation progresses, including one `aggregate=needsYou` line, and `0 session(s), aggregate=asleep` at the end.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeWidget
git commit -m "feat: app skeleton with session directory monitor"
```

---

### Task 9: Theme + CritterRenderer

**Files:**
- Create: `Sources/ClaudeWidget/Theme.swift`
- Create: `Sources/ClaudeWidget/CritterRenderer.swift`

**Interfaces:**
- Consumes: `CritterGeometry`, `CritterPose`, `AggregateState`.
- Produces: `NSColor.init(hex: UInt32)`, `Theme` (colors `accentLight/accentDark/claudeOrange/faintLight/faintDark/panelBg/panelBorder/panelFg/panelFaint`, `critterColor(state:darkAppearance:) -> (NSColor, CGFloat)`, `monoFont(_ size: CGFloat) -> NSFont`), `CritterRenderer.image(pose:color:opacity:pointSize:) -> NSImage` (default pointSize 18).

- [ ] **Step 1: Write Theme.swift**

```swift
import AppKit
import ClaudeWidgetCore

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

enum Theme {
    static let accentLight = NSColor(hex: 0x4B46F5)
    static let accentDark = NSColor(hex: 0x8A86FF)
    static let claudeOrange = NSColor(hex: 0xD97757)
    static let faintLight = NSColor(hex: 0x6F6E79)
    static let faintDark = NSColor(hex: 0x908F99)

    static let panelBg = NSColor(hex: 0x1C1B1F)
    static let panelBorder = NSColor(hex: 0x2A292E)
    static let panelFg = NSColor(hex: 0xECECEA)
    static let panelFaint = NSColor(hex: 0x908F99)

    static func monoFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Geist Mono", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func critterColor(state: AggregateState, darkAppearance: Bool) -> (color: NSColor, opacity: CGFloat) {
        switch state {
        case .asleep:
            return (darkAppearance ? faintDark : faintLight, 0.45)
        case .ready, .waiting:
            return (darkAppearance ? accentDark : accentLight, 0.70)
        case .working:
            return (darkAppearance ? accentDark : accentLight, 1.0)
        case .needsYou:
            return (claudeOrange, 1.0)
        }
    }
}
```

- [ ] **Step 2: Write CritterRenderer.swift**

```swift
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
```

- [ ] **Step 3: Visual verification — dump every pose and state to PNGs**

Add a temporary debug entry to `Sources/ClaudeWidget/main.swift`, ABOVE the `NSApplication` lines:

```swift
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
```

Run: `swift run ClaudeWidget --dump-poses /tmp/critter-poses && open /tmp/critter-poses`
Expected: 6 PNGs. Check: official critter silhouette; walkA lifts legs 1 and 3; blink has no eyes; asleep has low slit eyes and looks dim; orange variant is `#D97757`.

- [ ] **Step 4: Commit** (keep the `--dump-poses` block; `bundle.sh` reuses the pattern for the app icon)

```bash
git add Sources/ClaudeWidget
git commit -m "feat: theme tokens and critter image renderer"
```

---

### Task 10: StatusItemController — live states and animations

**Files:**
- Create: `Sources/ClaudeWidget/StatusItemController.swift`
- Modify: `Sources/ClaudeWidget/AppDelegate.swift` (swap placeholder for the controller)

**Interfaces:**
- Consumes: `CritterRenderer`, `Theme`, `AggregateState`, `WidgetConstants`, `CritterPose`.
- Produces: `StatusItemController` (`applyState(_ state: AggregateState)`, `onClick: (() -> Void)?`, `var button: NSStatusBarButton?` for popover anchoring).

- [ ] **Step 1: Write StatusItemController.swift**

```swift
import AppKit
import ClaudeWidgetCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var aggregate: AggregateState = .asleep
    private var walkTimer: Timer?
    private var blinkWorkItem: DispatchWorkItem?
    private var walkFrameA = true
    private var appearanceObservation: NSKeyValueObservation?

    var onClick: (() -> Void)?
    var button: NSStatusBarButton? { statusItem.button }

    override init() {
        super.init()
        statusItem.button?.wantsLayer = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.render(pose: self?.currentBasePose ?? .idle) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyState(.asleep)
    }

    @objc private func clicked() { onClick?() }

    @objc private func motionPreferenceChanged() {
        Task { @MainActor in self.applyState(self.aggregate) }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var currentBasePose: CritterPose {
        switch aggregate {
        case .asleep: return .asleep
        case .working: return reduceMotion ? .idle : (walkFrameA ? .walkA : .walkB)
        default: return .idle
        }
    }

    func applyState(_ state: AggregateState) {
        aggregate = state
        walkTimer?.invalidate(); walkTimer = nil
        blinkWorkItem?.cancel(); blinkWorkItem = nil
        stopPulse()

        switch state {
        case .asleep:
            render(pose: .asleep)
        case .ready, .waiting:
            render(pose: .idle)
            if !reduceMotion { scheduleBlink() }
        case .working:
            walkFrameA = true
            render(pose: currentBasePose)
            if !reduceMotion {
                walkTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.walkFrameDuration,
                                                 repeats: true) { _ in
                    Task { @MainActor in
                        self.walkFrameA.toggle()
                        self.render(pose: self.currentBasePose)
                    }
                }
            }
        case .needsYou:
            render(pose: .idle)
            if !reduceMotion { startPulse() }
        }
    }

    private func scheduleBlink() {
        let delay = TimeInterval.random(in: WidgetConstants.blinkIntervalRange)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.aggregate == .ready || self.aggregate == .waiting else { return }
            self.render(pose: .blink)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard self.aggregate == .ready || self.aggregate == .waiting else { return }
                self.render(pose: .idle)
                self.scheduleBlink()
            }
        }
        blinkWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startPulse() {
        guard let layer = statusItem.button?.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.55
        animation.duration = WidgetConstants.pulsePeriod / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "pulse")
    }

    private func stopPulse() {
        statusItem.button?.layer?.removeAnimation(forKey: "pulse")
        statusItem.button?.layer?.opacity = 1
    }

    private func render(pose: CritterPose) {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (color, opacity) = Theme.critterColor(state: aggregate, darkAppearance: dark)
        button.image = CritterRenderer.image(pose: pose, color: color, opacity: opacity)
    }
}
```

- [ ] **Step 2: Wire it into AppDelegate.swift** (full replacement of the file)

```swift
import AppKit
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notchAlertsEnabled": true])

        statusController = StatusItemController()

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] old, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.statusController.applyState(aggregate)
            NSLog("claude-widget: \(new.count) session(s), aggregate=\(aggregate), peeks=\(peeks.count)")
        }
        monitor.start()
    }
}
```

- [ ] **Step 3: Verify all four states live**

```bash
swift build && .build/debug/ClaudeWidget & APP_PID=$!
sleep 2 && scripts/simulate.sh
kill $APP_PID
```
Expected in the menu bar: dim gray critter at launch → indigo critter that starts **walking** on `UserPromptSubmit` → turns **orange and pulses** during the 6 s `PermissionRequest` window → walks again → still indigo (waiting) after `Stop` → dim asleep after `SessionEnd`. Blink check: while in `waiting` (5 s window) the critter blinks if you catch it.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeWidget
git commit -m "feat: animated critter status item driven by session state"
```

---

### Task 11: AppModel + Popover (session list, toggles, quit)

**Files:**
- Create: `Sources/ClaudeWidget/AppModel.swift`
- Create: `Sources/ClaudeWidget/PopoverView.swift`
- Modify: `Sources/ClaudeWidget/AppDelegate.swift`

**Interfaces:**
- Consumes: `Session`, `SessionState`, `Theme`, `StatusItemController.button`, `SessionMonitor`.
- Produces: `AppModel: ObservableObject` (`@Published var sessions: [Session]`, `@Published var notchAlerts: Bool` persisted to UserDefaults key `"notchAlertsEnabled"`, `@Published var launchAtLogin: Bool` via `SMAppService.mainApp`, `@Published var hooksInstalled: Bool` and `installHooks()/removeHooks()` stubs that Task 13 fills — declare them now as empty methods), `PopoverView(model:)` SwiftUI view 300 pt wide.

- [ ] **Step 1: Write AppModel.swift**

```swift
import AppKit
import Combine
import ServiceManagement
import ClaudeWidgetCore

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var hooksInstalled = false

    @Published var notchAlerts: Bool {
        didSet { UserDefaults.standard.set(notchAlerts, forKey: "notchAlertsEnabled") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Fails when running unbundled (swift run); reflect reality.
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    init() {
        notchAlerts = UserDefaults.standard.bool(forKey: "notchAlertsEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func installHooks() {}   // implemented in Task 13
    func removeHooks() {}    // implemented in Task 13
    func refreshHooksStatus() {}  // implemented in Task 13
}
```

- [ ] **Step 2: Write PopoverView.swift**

```swift
import SwiftUI
import ClaudeWidgetCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SESSIONS")
                .font(Font(Theme.monoFont(11)))
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if model.sessions.isEmpty {
                Text("No sessions. The critter sleeps.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ForEach(model.sessions, id: \.sessionId) { session in
                    SessionRow(session: session, dark: colorScheme == .dark)
                    Divider().padding(.leading, 16)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Notch alerts", isOn: $model.notchAlerts)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack {
                hooksControl
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .onAppear { model.refreshHooksStatus() }
    }

    @ViewBuilder private var hooksControl: some View {
        if model.hooksInstalled {
            HStack(spacing: 6) {
                Text("Hooks installed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Remove") { model.removeHooks() }
                    .font(.system(size: 12))
                    .buttonStyle(.link)
            }
        } else {
            Button("Install hooks") { model.installHooks() }
                .font(.system(size: 13))
        }
    }
}

struct SessionRow: View {
    let session: Session
    let dark: Bool
    @State private var hovering = false

    private var dotColor: Color {
        switch session.state {
        case .working: return Color(nsColor: dark ? Theme.accentDark : Theme.accentLight)
        case .needsYou: return Color(nsColor: Theme.claudeOrange)
        case .waiting: return Color(nsColor: NSColor(hex: dark ? 0x53B483 : 0x1A7A4D))
        case .ready: return Color(nsColor: dark ? Theme.faintDark : Theme.faintLight)
        }
    }

    private var elapsed: String {
        let seconds = max(0, Date().timeIntervalSince1970 - session.updatedAt)
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(session.projectName)
                    .font(.system(size: 14))
                Spacer()
                Text(elapsed)
                    .font(Font(Theme.monoFont(12)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .onHover { hovering = $0 }
        }
    }
}
```

- [ ] **Step 3: Wire the popover into AppDelegate.swift** (full replacement)

```swift
import AppKit
import SwiftUI
import ClaudeWidgetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionMonitor!
    private var statusController: StatusItemController!
    private var model: AppModel!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notchAlertsEnabled": true])

        model = AppModel()
        statusController = StatusItemController()

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        statusController.onClick = { [weak self] in self?.togglePopover() }

        monitor = SessionMonitor()
        monitor.onChange = { [weak self] old, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.model.sessions = new
            self.statusController.applyState(aggregate)
        }
        monitor.start()
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    func openPopover() {
        guard let button = statusController.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
```

- [ ] **Step 4: Verify the popover live**

```bash
swift build && .build/debug/ClaudeWidget & APP_PID=$!
sleep 1 && scripts/simulate.sh &
```
Click the critter while the simulation runs. Expected: popover with `SESSIONS` mono label, one row `demo-project` with a state dot that is indigo (working) or orange (needs you) as the simulation progresses, elapsed `now`, both toggles, `Install hooks` button, Quit. After the simulation: empty state "No sessions. The critter sleeps." Toggling Launch at login while unbundled flips back (expected). Then `kill $APP_PID`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeWidget
git commit -m "feat: session popover with toggles"
```

---

### Task 12: NotchPanelController + PeekView

**Files:**
- Create: `Sources/ClaudeWidget/NotchPanel.swift`
- Modify: `Sources/ClaudeWidget/AppDelegate.swift` (wire peeks)

**Interfaces:**
- Consumes: `Session`, `PeekEvent`, `AggregateState`, `Theme`, `CritterRenderer`, `WidgetConstants`, `AppDelegate.openPopover()`.
- Produces: `NotchPanelController` (`showNeedsYou(_ session: Session)`, `showFinished(_ session: Session, duration: TimeInterval)`, `resolveIfSticky(aggregate: AggregateState)`, `onTap: (() -> Void)?`; respects UserDefaults `"notchAlertsEnabled"`).

- [ ] **Step 1: Write NotchPanel.swift**

```swift
import AppKit
import SwiftUI
import ClaudeWidgetCore

@MainActor
final class NotchPanelController {
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var sticky = false

    var onTap: (() -> Void)?

    func showNeedsYou(_ session: Session) {
        let detail = [session.projectName, session.message].compactMap { $0 }.joined(separator: " · ")
        show(title: "Needs you", detail: detail, color: Theme.claudeOrange, sticky: true)
    }

    func showFinished(_ session: Session, duration: TimeInterval) {
        show(title: "Finished", detail: "\(session.projectName) · \(Self.format(duration))",
             color: Theme.accentDark, sticky: false)
    }

    func resolveIfSticky(aggregate: AggregateState) {
        if sticky && aggregate != .needsYou { hide() }
    }

    static func format(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private func show(title: String, detail: String, color: NSColor, sticky: Bool) {
        guard UserDefaults.standard.bool(forKey: "notchAlertsEnabled") else { return }
        guard let screen = builtInScreen() else { return }

        hideTimer?.invalidate(); hideTimer = nil
        self.sticky = sticky

        let width: CGFloat = 340
        let height: CGFloat = 56
        let notchBottom = screen.frame.maxY - screen.safeAreaInsets.top
        let finalFrame = NSRect(x: screen.frame.midX - width / 2,
                                y: notchBottom - height, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: PeekView(
            title: title, detail: detail, critterColor: Color(nsColor: color),
            onTap: { [weak self] in
                self?.onTap?()
                self?.hide()
            }))

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.setFrame(reduce ? finalFrame : finalFrame.offsetBy(dx: 0, dy: 12), display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.15 : WidgetConstants.peekSlideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        if !sticky {
            hideTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.finishedPeekAutoHide,
                                             repeats: false) { _ in
                Task { @MainActor in self.hide() }
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        hideTimer?.invalidate(); hideTimer = nil
        sticky = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

struct PeekView: View {
    let title: String
    let detail: String
    let critterColor: Color
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: CritterRenderer.image(
                pose: .idle,
                color: NSColor(critterColor),
                opacity: 1.0, pointSize: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.panelFg))
                Text(detail)
                    .font(Font(Theme.monoFont(11)))
                    .foregroundStyle(Color(nsColor: Theme.panelFaint))
                    .lineLimit(1)
            }
            Spacer()
            Text("click to open")
                .font(Font(Theme.monoFont(10)))
                .foregroundStyle(Color(nsColor: Theme.panelFaint))
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: 340, height: 56, alignment: .center)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(Color(nsColor: Theme.panelBg))
                .overlay(
                    UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                        .strokeBorder(Color(nsColor: Theme.panelBorder), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
```

- [ ] **Step 2: Wire peeks in AppDelegate.swift.** Add a property `private var notch: NotchPanelController!`, and in `applicationDidFinishLaunching` after `statusController.onClick = ...` add:

```swift
        notch = NotchPanelController()
        notch.onTap = { [weak self] in self?.openPopover() }
```

Then replace the `monitor.onChange` closure body with:

```swift
        monitor.onChange = { [weak self] old, new, peeks in
            guard let self else { return }
            let aggregate = Aggregator.aggregate(new)
            self.model.sessions = new
            self.statusController.applyState(aggregate)
            self.notch.resolveIfSticky(aggregate: aggregate)
            for peek in peeks {
                switch peek {
                case .needsYou(let session):
                    self.notch.showNeedsYou(session)
                case .finished(let session, let duration):
                    self.notch.showFinished(session, duration: duration)
                }
            }
        }
```

- [ ] **Step 3: Verify both peeks live**

```bash
swift build && .build/debug/ClaudeWidget & APP_PID=$!
sleep 1 && scripts/simulate.sh
scripts/simulate.sh finished
kill $APP_PID
```
Expected: during the `PermissionRequest` window, a dark panel slides down from under the notch reading "Needs you / demo-project · Bash" with an orange critter; it stays while orange (sticky), disappears when the simulation proceeds (state resolves). The `finished` run shows "Finished / demo-project · 2m 0s" with an indigo critter that auto-hides after 5 s. Clicking a peek opens the popover. Toggle "Notch alerts" off in the popover, re-run: no peek appears.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeWidget
git commit -m "feat: notch peek panel for needs-you and finished events"
```

---

### Task 13: HookInstaller (backup, merge, remove) wired to the popover

**Files:**
- Create: `Sources/ClaudeWidget/HookInstaller.swift`
- Modify: `Sources/ClaudeWidget/AppModel.swift` (fill the three stub methods)

**Interfaces:**
- Consumes: `HooksConfigMerger`, `WidgetConstants`.
- Produces: `HookInstaller` (`install() throws`, `remove() throws`, `isInstalled() -> Bool`), used by `AppModel.installHooks()/removeHooks()/refreshHooksStatus()`.

- [ ] **Step 1: Write HookInstaller.swift**

```swift
import Foundation
import ClaudeWidgetCore

struct HookInstaller {
    /// The command string written into settings.json. "$HOME" is expanded by
    /// the shell Claude Code uses to run hooks, so the config is portable.
    static let settingsBinaryPath = "$HOME/.claude/claude-widget/bin/claude-widget-hook"

    /// The claude-widget-hook binary ships next to the app executable, both in
    /// `swift build` output and inside Claude Widget.app/Contents/MacOS.
    private var bundledHookBinary: URL {
        Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("claude-widget-hook")
    }

    private func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: WidgetConstants.claudeSettings) else { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: WidgetConstants.claudeSettings)
    }

    private func backupSettings() throws {
        guard FileManager.default.fileExists(atPath: WidgetConstants.claudeSettings.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = WidgetConstants.claudeSettings
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json.backup-claude-widget-\(stamp)")
        try FileManager.default.copyItem(at: WidgetConstants.claudeSettings, to: backup)
    }

    func install() throws {
        try FileManager.default.createDirectory(at: WidgetConstants.binDir,
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: WidgetConstants.hookBinary.path) {
            try FileManager.default.removeItem(at: WidgetConstants.hookBinary)
        }
        try FileManager.default.copyItem(at: bundledHookBinary, to: WidgetConstants.hookBinary)

        try backupSettings()
        let merged = HooksConfigMerger.merge(settings: try readSettings(),
                                             binaryPath: Self.settingsBinaryPath)
        try writeSettings(merged)
    }

    func remove() throws {
        try backupSettings()
        let stripped = HooksConfigMerger.remove(settings: try readSettings())
        try writeSettings(stripped)
    }

    /// Copies the bundled hook binary over the installed one without touching
    /// settings.json. Called on every launch so app updates propagate (spec §4.4).
    func refreshBinary() throws {
        try FileManager.default.createDirectory(at: WidgetConstants.binDir,
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: WidgetConstants.hookBinary.path) {
            try FileManager.default.removeItem(at: WidgetConstants.hookBinary)
        }
        try FileManager.default.copyItem(at: bundledHookBinary, to: WidgetConstants.hookBinary)
    }

    /// Installed means: settings entries present AND the binary exists.
    /// A missing binary (spec §8) resurfaces the Install button.
    func isInstalled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return HooksConfigMerger.isInstalled(settings: settings)
            && FileManager.default.fileExists(atPath: WidgetConstants.hookBinary.path)
    }
}
```

- [ ] **Step 2: Fill the AppModel stubs.** Replace the three empty methods in `AppModel.swift` with:

```swift
    private let installer = HookInstaller()

    func installHooks() {
        try? installer.install()
        refreshHooksStatus()
    }

    func removeHooks() {
        try? installer.remove()
        refreshHooksStatus()
    }

    func refreshHooksStatus() {
        hooksInstalled = installer.isInstalled()
        if hooksInstalled {
            try? installer.refreshBinary()
        }
    }
```

Also add one line at the end of `AppModel.init()` so the launch-time binary refresh happens without waiting for the popover to open:

```swift
        refreshHooksStatus()
```

- [ ] **Step 3: Verify against the real settings.json** (backup-first makes this safe)

```bash
cp ~/.claude/settings.json /tmp/settings-before.json
swift build && .build/debug/ClaudeWidget & APP_PID=$!
```
Click the critter → "Install hooks". Then:
```bash
ls ~/.claude/settings.json.backup-claude-widget-* && ls -l ~/.claude/claude-widget/bin/
python3 - <<'EOF'
import json
s = json.load(open(f"{__import__('os').path.expanduser('~')}/.claude/settings.json"))
hooks = s.get("hooks", {})
ours = sum(1 for evt in hooks.values() for e in evt
           for h in e.get("hooks", []) if "claude-widget-hook" in h.get("command", ""))
print("our entries:", ours)
print("superset preserved:", any("SUPERSET" in h.get("command", "")
      for evt in hooks.values() for e in evt for h in e.get("hooks", [])))
EOF
```
Expected: backup file exists, `claude-widget-hook` binary in `bin/`, `our entries: 7`, `superset preserved: True`. Popover now shows "Hooks installed" with Remove. Click Remove → re-run the python check → `our entries: 0`, `superset preserved: True`. Click Install again (leave installed for Task 14). `kill $APP_PID`.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeWidget
git commit -m "feat: in-app hook install with settings backup"
```

---

### Task 14: bundle.sh, app icon, /Applications install, end-to-end test, README

**Files:**
- Create: `scripts/bundle.sh`
- Modify: `Sources/ClaudeWidget/main.swift` (add `--render-icon` mode next to `--dump-poses`)
- Create: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: `build/Claude Widget.app`, optionally installed to `/Applications` with `scripts/bundle.sh --install`.

- [ ] **Step 1: Add icon render mode to main.swift.** Below the `--dump-poses` block, add:

```swift
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-icon"),
   CommandLine.arguments.count > flagIndex + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        // ~78% content with padding, matching macOS icon grid margins
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let critter = CritterRenderer.image(pose: .idle, color: Theme.accentLight,
                                                opacity: 1.0, pointSize: rect.width * 0.78)
            critter.draw(in: rect.insetBy(dx: rect.width * 0.11, dy: rect.height * 0.11))
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
        }
    }
    exit(0)
}
```

- [ ] **Step 2: Write scripts/bundle.sh**

```bash
#!/bin/bash
# Builds Claude Widget.app. With --install, copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Claude Widget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ClaudeWidget "$APP/Contents/MacOS/Claude Widget"
cp .build/release/claude-widget-hook "$APP/Contents/MacOS/"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
.build/release/ClaudeWidget --render-icon "$ICONSET"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  cp "$ICONSET/icon_${d}x${d}.png" "$ICONSET/icon_${s}x${s}@2x.png"
done
rm "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Widget</string>
    <key>CFBundleDisplayName</key><string>Claude Widget</string>
    <key>CFBundleExecutable</key><string>Claude Widget</string>
    <key>CFBundleIdentifier</key><string>com.glebstarchikov.claude-widget</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built: $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/Claude Widget.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Widget.app"
  echo "installed and launched"
fi
```

- [ ] **Step 3: Build, install, and verify the bundle**

```bash
chmod +x scripts/bundle.sh
scripts/bundle.sh --install
```
Expected: critter appears in the menu bar with no Dock icon; `Claude Widget.app` in /Applications has the indigo critter icon. Toggle "Launch at login" in the popover: it sticks now (bundled app). Note: hooks were installed in Task 13 pointing at `~/.claude/claude-widget/bin/`, which is bundle-independent; click "Install hooks" once more anyway to refresh the binary copy from the release build.

- [ ] **Step 4: End-to-end test with a real Claude Code session** (success criteria 1–5 from the spec)

In a terminal:
```bash
cd ~/claude-widget && claude
```
Ask Claude something involving a tool (e.g. "run git log --oneline -3 and summarize"). Verify against the spec:
1. Critter wakes and walks within ~1 s of submitting the prompt.
2. If a permission prompt appears, critter turns orange + pulses, notch peek says "Needs you".
3. Answering resumes the walk.
4. `Stop` returns it to still indigo (waiting); a 60 s+ turn shows the "Finished" peek.
5. Exit the session (`/exit`): file removed, critter sleeps (or GC on next reload).

Then check the resource footprint (success criterion 6):
```bash
ps -o rss=,comm= -p "$(pgrep -f 'Claude Widget.app/Contents/MacOS')"
```
Expected: RSS under 51200 (KB, i.e. < 50 MB).

Record any deviation as a bug before proceeding.

- [ ] **Step 5: Write README.md**

```markdown
# Claude Widget

The Claude Code critter, living in your Mac menu bar. It mirrors your live
Claude Code sessions: walks while Claude works, turns orange and pulses when
Claude needs you, sleeps when nothing is running. Interruption-worthy moments
slide out of the notch.

Design system: [glebstar/design](https://github.com/glebstar) tokens (indigo
accent); Claude orange #D97757 reserved for "Claude is asking".

## Build

    scripts/bundle.sh --install

Then click the critter → "Install hooks" (backs up ~/.claude/settings.json
first). Hooks are async and add zero latency to Claude sessions.

## Develop

    swift test                  # core logic tests
    swift run ClaudeWidget      # run unbundled
    scripts/simulate.sh         # fake session lifecycle, no tokens burned
    scripts/simulate.sh finished  # long-task "Finished" peek

## Uninstall

Popover → "Remove hooks", quit the app, delete /Applications/Claude
Widget.app and ~/.claude/claude-widget.

Not affiliated with Anthropic. The critter and the Claude Code logo are
Anthropic trademarks; this is a personal tool.
```

- [ ] **Step 6: Final full check and commit**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass.

```bash
git add scripts/bundle.sh Sources/ClaudeWidget/main.swift README.md
git commit -m "feat: app bundling, icon, and readme"
```

---

## Deviations and completion

- Any deviation discovered during execution (API mismatch, macOS behavior difference) gets fixed in the task where it surfaces; if it changes an interface, update the spec section it came from in the same commit.
- After Task 14, run the superpowers:finishing-a-development-branch skill: all work is on `main` in a personal repo, so this collapses to a final review + tag if desired.
