# Phone Alerts (ntfy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Buzz the user's iPhone when a Claude Code session needs input or a long task finishes, via ntfy push fired from the menu bar app.

**Architecture:** The menu bar app already receives `[PeekEvent]` (needs-you / finished transitions) in `SessionMonitor.onChange`. We add pure ntfy payload/request builders in `ClaudeWidgetCore` (tested), a thin fire-and-forget `PushNotifier` in the app, one line in the existing peek loop, and a "Notify my phone" popover section. No hook changes, no new dependencies.

**Tech Stack:** Swift 5.10, SwiftPM, AppKit/SwiftUI, Foundation `URLSession`. ntfy HTTP publish API.

## Global Constraints

- Platform: macOS 14+, Swift tools 5.10, SwiftPM only (no Xcode project).
- **No new dependencies** — Foundation `URLSession` only.
- **Do not touch the hook** (`ClaudeWidgetHook`) or `HooksConfigMerger` — this feature is entirely app-fired.
- Bundle id (for `defaults` domain in manual tests): `com.glebstarchikov.claude-widget`.
- **Privacy invariant:** the push body is the project folder name only — plus the duration for `.finished`. It must never contain `session.message`, `session.tool`, commands, or paths.
- **Off by default:** no network traffic until the user enables the toggle.
- Existing test suite is XCTest (`ClaudeWidgetCoreTests`); only `ClaudeWidgetCore` has unit tests. App-target code is verified by build + manual run.
- Commit messages use conventional prefixes (`feat:` / `refactor:` / `docs:`) and end with the `Co-Authored-By` trailer used elsewhere in the repo.

---

### Task 1: Hoist the duration formatter into Core

Move the `4m 20s` formatter out of `NotchPanelController` so both the notch and the push payload share one implementation (the spec's in-scope cleanup). Pure + unit-tested.

**Files:**
- Create: `Sources/ClaudeWidgetCore/DurationFormat.swift`
- Create: `Tests/ClaudeWidgetCoreTests/DurationFormatTests.swift`
- Modify: `Sources/ClaudeWidget/NotchPanel.swift` (remove the private `format`, call `DurationFormat.short`)

**Interfaces:**
- Produces: `enum DurationFormat { static func short(_ duration: TimeInterval) -> String }` — `"45s"`, `"4m 20s"`, clamps negatives to `"0s"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeWidgetCoreTests/DurationFormatTests.swift`:

```swift
import XCTest
@testable import ClaudeWidgetCore

final class DurationFormatTests: XCTestCase {
    func testSecondsOnly() { XCTAssertEqual(DurationFormat.short(45), "45s") }
    func testZero() { XCTAssertEqual(DurationFormat.short(0), "0s") }
    func testMinutesAndSeconds() { XCTAssertEqual(DurationFormat.short(260), "4m 20s") }
    func testExactMinute() { XCTAssertEqual(DurationFormat.short(60), "1m 0s") }
    func testNegativeClampsToZero() { XCTAssertEqual(DurationFormat.short(-5), "0s") }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DurationFormatTests`
Expected: FAIL — `cannot find 'DurationFormat' in scope`.

- [ ] **Step 3: Create the implementation**

Create `Sources/ClaudeWidgetCore/DurationFormat.swift`:

```swift
import Foundation

public enum DurationFormat {
    /// Compact duration like "45s" or "4m 20s". Negative inputs clamp to "0s".
    public static func short(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter DurationFormatTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Point NotchPanel at the shared formatter**

In `Sources/ClaudeWidget/NotchPanel.swift`, change the `showFinished` body from `Self.format(duration)` to `DurationFormat.short(duration)`:

```swift
    func showFinished(_ session: Session, duration: TimeInterval) {
        show(title: "Finished", detail: "\(session.projectName) · \(DurationFormat.short(duration))",
             color: Theme.accentDark, dismissal: .autoHide)
    }
```

Then delete the now-unused private static `format`:

```swift
    static func format(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
```

- [ ] **Step 6: Verify the whole build + suite are green**

Run: `swift build && swift test`
Expected: build succeeds; all existing tests + the 5 new ones pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeWidgetCore/DurationFormat.swift Tests/ClaudeWidgetCoreTests/DurationFormatTests.swift Sources/ClaudeWidget/NotchPanel.swift
git commit -m "refactor: hoist duration formatter into Core (shared by notch + push)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: ntfy payload + request builders (Core)

Two pure functions: `PeekEvent -> PushPayload` (with the privacy rule) and `PushPayload -> URLRequest` (the ntfy publish shape). Both unit-tested; no networking.

**Files:**
- Create: `Sources/ClaudeWidgetCore/PushMessage.swift`
- Create: `Sources/ClaudeWidgetCore/PushRequest.swift`
- Create: `Tests/ClaudeWidgetCoreTests/PushMessageTests.swift`
- Create: `Tests/ClaudeWidgetCoreTests/PushRequestTests.swift`

**Interfaces:**
- Consumes: `PeekEvent` (from `Aggregator.swift`), `Session.projectName`, `DurationFormat.short` (Task 1).
- Produces:
  - `enum PushPriority: String { case min, low, default, high, urgent }`
  - `struct PushPayload { let title: String; let body: String; let priority: PushPriority; let tags: [String] }`
  - `enum PushMessage { static func from(_ peek: PeekEvent) -> PushPayload }`
  - `enum PushRequest { static func make(payload: PushPayload, server: String, topic: String) -> URLRequest? }`

- [ ] **Step 1: Write the failing PushMessage tests**

Create `Tests/ClaudeWidgetCoreTests/PushMessageTests.swift`:

```swift
import XCTest
@testable import ClaudeWidgetCore

final class PushMessageTests: XCTestCase {
    private func session(cwd: String, message: String? = nil, tool: String? = nil) -> Session {
        Session(sessionId: "s1", state: .needsYou, cwd: cwd, message: message, tool: tool, updatedAt: 0)
    }

    func testNeedsYouPayload() {
        let p = PushMessage.from(.needsYou(session(cwd: "/Users/x/claude-widget")))
        XCTAssertEqual(p.title, "Claude needs you")
        XCTAssertEqual(p.body, "claude-widget")
        XCTAssertEqual(p.priority, .urgent)
        XCTAssertEqual(p.tags, ["eyes"])
    }

    func testFinishedPayload() {
        let p = PushMessage.from(.finished(session(cwd: "/Users/x/claude-widget"), duration: 260))
        XCTAssertEqual(p.title, "Finished")
        XCTAssertEqual(p.body, "claude-widget · 4m 20s")
        XCTAssertEqual(p.priority, .high)
        XCTAssertEqual(p.tags, ["white_check_mark"])
    }

    // Privacy invariant: sensitive fields must never reach the body.
    func testBodyNeverLeaksMessageOrTool() {
        let s = session(cwd: "/Users/x/secret-proj", message: "rm -rf /tmp/x", tool: "Bash: rm -rf /tmp/x")
        let p = PushMessage.from(.needsYou(s))
        XCTAssertEqual(p.body, "secret-proj")
        XCTAssertFalse(p.body.contains("rm -rf"))
        XCTAssertFalse(p.body.contains("Bash"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PushMessageTests`
Expected: FAIL — `cannot find 'PushMessage' in scope`.

- [ ] **Step 3: Create PushMessage**

Create `Sources/ClaudeWidgetCore/PushMessage.swift`:

```swift
import Foundation

public enum PushPriority: String, Equatable, Sendable {
    case min, low, `default`, high, urgent
}

public struct PushPayload: Equatable, Sendable {
    public let title: String
    public let body: String
    public let priority: PushPriority
    public let tags: [String]

    public init(title: String, body: String, priority: PushPriority, tags: [String]) {
        self.title = title
        self.body = body
        self.priority = priority
        self.tags = tags
    }
}

public enum PushMessage {
    /// Maps a peek event to an ntfy payload. Privacy rule: the body carries only
    /// the project (folder) name — plus the duration for `.finished` — never the
    /// session's message, tool, commands, or paths. The category rides in the title.
    public static func from(_ peek: PeekEvent) -> PushPayload {
        switch peek {
        case .needsYou(let session):
            return PushPayload(title: "Claude needs you", body: session.projectName,
                               priority: .urgent, tags: ["eyes"])
        case .finished(let session, let duration):
            return PushPayload(title: "Finished",
                               body: "\(session.projectName) · \(DurationFormat.short(duration))",
                               priority: .high, tags: ["white_check_mark"])
        }
    }
}
```

- [ ] **Step 4: Run to verify PushMessage passes**

Run: `swift test --filter PushMessageTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the failing PushRequest tests**

Create `Tests/ClaudeWidgetCoreTests/PushRequestTests.swift`:

```swift
import XCTest
@testable import ClaudeWidgetCore

final class PushRequestTests: XCTestCase {
    private let payload = PushPayload(title: "Claude needs you", body: "claude-widget",
                                      priority: .urgent, tags: ["eyes"])

    func testBuildsPostToServerTopic() {
        let r = PushRequest.make(payload: payload, server: "https://ntfy.sh", topic: "claude-abc123")
        XCTAssertEqual(r?.url?.absoluteString, "https://ntfy.sh/claude-abc123")
        XCTAssertEqual(r?.httpMethod, "POST")
    }

    func testSetsHeadersAndBody() {
        let r = PushRequest.make(payload: payload, server: "https://ntfy.sh", topic: "t")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Title"), "Claude needs you")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Priority"), "urgent")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Tags"), "eyes")
        XCTAssertEqual(r?.httpBody, Data("claude-widget".utf8))
    }

    func testTrailingSlashServerNormalized() {
        let r = PushRequest.make(payload: payload, server: "https://ntfy.sh/", topic: "t")
        XCTAssertEqual(r?.url?.absoluteString, "https://ntfy.sh/t")
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --filter PushRequestTests`
Expected: FAIL — `cannot find 'PushRequest' in scope`.

- [ ] **Step 7: Create PushRequest**

Create `Sources/ClaudeWidgetCore/PushRequest.swift`:

```swift
import Foundation

public enum PushRequest {
    /// Builds the ntfy publish request: POST <server>/<topic>, message in the body,
    /// Title/Priority/Tags in headers. Returns nil if the URL can't be formed.
    public static func make(payload: PushPayload, server: String, topic: String) -> URLRequest? {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard let url = URL(string: "\(base)/\(topic)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(payload.title, forHTTPHeaderField: "Title")
        request.setValue(payload.priority.rawValue, forHTTPHeaderField: "Priority")
        request.setValue(payload.tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        request.httpBody = Data(payload.body.utf8)
        return request
    }
}
```

- [ ] **Step 8: Run to verify PushRequest passes, then the full suite**

Run: `swift test --filter PushRequestTests` → PASS (3 tests).
Run: `swift test` → all pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/ClaudeWidgetCore/PushMessage.swift Sources/ClaudeWidgetCore/PushRequest.swift Tests/ClaudeWidgetCoreTests/PushMessageTests.swift Tests/ClaudeWidgetCoreTests/PushRequestTests.swift
git commit -m "feat: ntfy payload + request builders in Core" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: PushNotifier + wire into the peek loop (App)

The thin app-side sender and its single integration line. No unit tests (App target); verified by build + a real end-to-end push driven by `simulate.sh`.

**Files:**
- Create: `Sources/ClaudeWidget/PushNotifier.swift`
- Modify: `Sources/ClaudeWidget/AppDelegate.swift` (register `pushEnabled` default, hold a `PushNotifier`, call `send` in the peek loop)

**Interfaces:**
- Consumes: `PushMessage.from`, `PushRequest.make`, `PushPayload`, `PeekEvent` (Task 2).
- Produces: `struct PushNotifier { func send(_ peek: PeekEvent); func sendTest() }` — reads `pushEnabled` / `pushTopic` / `pushServer` from `UserDefaults`.

- [ ] **Step 1: Create PushNotifier**

Create `Sources/ClaudeWidget/PushNotifier.swift`:

```swift
import Foundation
import ClaudeWidgetCore

/// Best-effort ntfy push for interruption-worthy peeks. Reads config from the
/// same UserDefaults as the notch toggles. Fire-and-forget: any failure is
/// swallowed, so a missed alert never perturbs the app or Claude.
struct PushNotifier {
    var defaults: UserDefaults = .standard

    private var enabled: Bool { defaults.bool(forKey: "pushEnabled") }
    private var topic: String { defaults.string(forKey: "pushTopic") ?? "" }
    private var server: String { defaults.string(forKey: "pushServer") ?? "https://ntfy.sh" }

    func send(_ peek: PeekEvent) {
        guard enabled, !topic.isEmpty else { return }
        post(PushMessage.from(peek))
    }

    /// Manual confirmation alert from the popover's "Send test" button.
    func sendTest() {
        guard !topic.isEmpty else { return }
        post(PushPayload(title: "Claude Widget", body: "Test alert · it works",
                         priority: .default, tags: ["bell"]))
    }

    private func post(_ payload: PushPayload) {
        guard let request = PushRequest.make(payload: payload, server: server, topic: topic) else { return }
        URLSession.shared.dataTask(with: request).resume()
    }
}
```

- [ ] **Step 2: Register the default + hold the notifier**

In `Sources/ClaudeWidget/AppDelegate.swift`, add `pushEnabled` to the registered defaults:

```swift
        UserDefaults.standard.register(defaults: [
            "notchAlertsEnabled": true,
            "notchProactiveEnabled": true,
            "pushEnabled": false,
        ])
```

And add a stored property alongside the other controllers (near the top of `AppDelegate`):

```swift
    private let pushNotifier = PushNotifier()
```

- [ ] **Step 3: Fire the push in the existing peek loop**

In the `monitor.onChange` closure, add one line at the top of the `for peek in peeks` loop:

```swift
                for peek in peeks {
                    self.pushNotifier.send(peek)
                    switch peek {
                    case .needsYou(let session):
                        self.notch.showNeedsYou(session)
                    case .finished(let session, let duration):
                        self.notch.showFinished(session, duration: duration)
                    }
                }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 5: Manual end-to-end verification**

Set a temporary topic, subscribe to it in a browser (no phone needed yet), reinstall, and drive a real needs-you transition:

```bash
defaults write com.glebstarchikov.claude-widget pushTopic "claude-manualtest$(date +%s)"
defaults write com.glebstarchikov.claude-widget pushEnabled -bool true
defaults read com.glebstarchikov.claude-widget pushTopic   # note the topic
# open https://ntfy.sh/<that-topic> in a browser to watch
scripts/bundle.sh --install                                # rebuild + relaunch with the new code
scripts/simulate.sh                                        # PermissionRequest → needs-you → push
```

Expected: within a few seconds of the `PermissionRequest` step, a **"Claude needs you" / demo-project** notification appears on the ntfy topic page. Then clean up:

```bash
defaults delete com.glebstarchikov.claude-widget pushEnabled
defaults delete com.glebstarchikov.claude-widget pushTopic
```

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeWidget/PushNotifier.swift Sources/ClaudeWidget/AppDelegate.swift
git commit -m "feat: fire ntfy push on needs-you/finished from the app" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Popover UI, config, and README (App)

The user-facing toggle: enable, auto-generate the topic, copy it, send a test. Plus README docs. Completes the feature.

**Files:**
- Modify: `Sources/ClaudeWidget/AppModel.swift` (`pushEnabled` / `pushTopic` published, topic generation, `sendTestPush()`)
- Modify: `Sources/ClaudeWidget/PopoverView.swift` (`import AppKit`; "Notify my phone" section)
- Modify: `README.md` (phone-alerts section)

**Interfaces:**
- Consumes: `PushNotifier.sendTest()` (Task 3); UserDefaults keys `pushEnabled` / `pushTopic`.
- Produces: `AppModel.pushEnabled: Bool`, `AppModel.pushTopic: String`, `AppModel.sendTestPush()`.

- [ ] **Step 1: Add config + test-send to AppModel**

In `Sources/ClaudeWidget/AppModel.swift`, add published properties after `notchProactive`:

```swift
    @Published var pushEnabled: Bool {
        didSet {
            UserDefaults.standard.set(pushEnabled, forKey: "pushEnabled")
            if pushEnabled, (UserDefaults.standard.string(forKey: "pushTopic") ?? "").isEmpty {
                let topic = "claude-" + Self.randomTopicSuffix()
                UserDefaults.standard.set(topic, forKey: "pushTopic")
                pushTopic = topic
            }
        }
    }
    @Published var pushTopic: String

    private let notifier = PushNotifier()

    private static func randomTopicSuffix() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<12).compactMap { _ in chars.randomElement() })
    }

    func sendTestPush() { notifier.sendTest() }
```

And initialize them in `init()` (before `refreshHooksStatus()`), noting `didSet` does not fire during `init`:

```swift
        pushEnabled = UserDefaults.standard.bool(forKey: "pushEnabled")
        pushTopic = UserDefaults.standard.string(forKey: "pushTopic") ?? ""
```

- [ ] **Step 2: Add the popover section**

In `Sources/ClaudeWidget/PopoverView.swift`, add `import AppKit` at the top (for `NSPasteboard`). Then, inside the settings `VStack` (the one holding the Launch/Notch toggles), add after the notch block:

```swift
                Toggle("Notify my phone", isOn: $model.pushEnabled)
                if model.pushEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(model.pushTopic)
                                .font(Font(Theme.monoFont(11)))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.pushTopic, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy topic")
                            Spacer()
                            Button("Send test") { model.sendTestPush() }
                                .font(.system(size: 11))
                        }
                        Text("Install the ntfy app → tap +, paste this topic")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Manual UI verification**

```bash
scripts/bundle.sh --install
```

Then click the menu bar critter → toggle **Notify my phone** on. Verify: a `claude-…` topic appears with a copy button and **Send test**. Open `https://ntfy.sh/<that topic>` in a browser, click **Send test**, and confirm a **"Claude Widget / Test alert · it works"** notification arrives. Toggle off and back on — the topic persists (not regenerated).

- [ ] **Step 5: Document in README**

In `README.md`, add after the "Settings (in the popover)" list item for "Show proactively":

```markdown
- **Notify my phone** — push a notification to your phone when a session needs
  you or a long task finishes, via [ntfy](https://ntfy.sh). Flip it on, install
  the ntfy app on your phone, tap **+**, and paste the topic shown in the popover
  (or scan nothing — just paste). Hit **Send test** to confirm the buzz.

  Only the project folder name leaves your Mac (never commands, paths, or
  prompts). The topic name is your only secret on the public `ntfy.sh` server —
  it's randomly generated and unguessable; point the `pushServer` default at your
  own ntfy instance if you want true end-to-end privacy.
```

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeWidget/AppModel.swift Sources/ClaudeWidget/PopoverView.swift README.md
git commit -m "feat: 'Notify my phone' popover section for ntfy alerts" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Manual E2E (whole feature, on the real phone)

After Task 4, one full real-device pass:

1. Install the **ntfy** app on the iPhone (App Store).
2. In the widget popover, enable **Notify my phone**, copy the topic.
3. In the ntfy app: **+ → Subscribe to topic →** paste the topic → server `ntfy.sh`.
4. Tap **Send test** in the popover → phone buzzes.
5. Run `scripts/simulate.sh` on the Mac → phone gets **"Claude needs you"**.
6. Run `scripts/simulate.sh finished` → phone gets **"Finished · … · Nm Ns"**.

## Self-Review Notes

- **Spec coverage:** app-fired integration (Task 3) ✓; `PushMessage` project-only body + privacy test (Task 2) ✓; `PushRequest` ntfy shape (Task 2) ✓; UserDefaults config `pushEnabled`/`pushTopic`/`pushServer` (Tasks 3–4) ✓; popover toggle + copyable topic + Send test (Task 4) ✓; duration-formatter hoist (Task 1) ✓; README (Task 4) ✓; off-by-default (`pushEnabled` registered `false`, Task 3) ✓; self-host via `pushServer` (read in `PushNotifier`, documented) ✓. QR intentionally omitted per revised spec.
- **Type consistency:** `PushPayload` / `PushPriority` / `PushMessage.from` / `PushRequest.make` signatures identical across Tasks 2–4; `DurationFormat.short` defined in Task 1 and consumed in Task 2.
- **No placeholders:** every code step is complete.
