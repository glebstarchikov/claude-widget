import XCTest
@testable import ClaudeWidgetCore

/// The approval coordinator's decisions (spec §8, §15, R17, R19, the 0.5 s settle).
final class ApprovalRulesTests: XCTestCase {
    private let terminal = "com.apple.Terminal"
    private let cursor = "com.todesktop.230313mzl4w4u92"

    private func request(tool: String = "Bash", owner: String? = "com.apple.Terminal", v: Int = 1) -> ApprovalRequest {
        var r = ApprovalRequest(id: "r1", sessionId: "s1", agentId: nil, cwd: "/tmp/p", toolName: tool,
                                toolDisplay: nil, toolInput: #"{"command":"npm test"}"#,
                                toolInputTruncated: false, ownerBundleId: owner)
        r.v = v
        return r
    }

    private func arrival(_ r: ApprovalRequest, setting: Bool = true, frontmost: String? = "com.apple.Safari",
                         held: Bool = false, pills: Bool = true, hub: Bool = false) -> ApprovalArrival {
        ApprovalRules.arrival(of: r, answerFromNotch: setting, frontmostBundleId: frontmost,
                              alreadyHeld: held, pillsShown: pills, hubOpen: hub)
    }

    // MARK: - Arrival

    func testHoldsARequestWhileGlebIsElsewhere() {
        XCTAssertEqual(arrival(request()), .hold)
        XCTAssertEqual(arrival(request(), frontmost: nil), .hold, "nothing frontmost isn't the owner")
        XCTAssertEqual(arrival(request(tool: "mcp__srv__tool")), .hold)
    }

    func testPassesWhenTheOwnerAppIsFrontmost() {
        XCTAssertEqual(arrival(request(owner: terminal), frontmost: terminal), .pass(.ownerActive))
        XCTAssertEqual(arrival(request(owner: terminal), frontmost: "com.apple.terminal"), .pass(.ownerActive),
                       "a case mismatch can only pass")
        XCTAssertEqual(arrival(request(owner: terminal), frontmost: cursor), .hold)
    }

    func testPassesWithoutAnOwnerToWatch() {
        XCTAssertEqual(arrival(request(owner: nil)), .pass(.noOwner))
        XCTAssertEqual(arrival(request(owner: "")), .pass(.noOwner))
        XCTAssertEqual(arrival(request(owner: nil), frontmost: nil), .pass(.noOwner), "nil never matches nil")
    }

    func testPassesWhenNoPillAndNoOpenHub() {
        XCTAssertEqual(arrival(request(), pills: false, hub: false), .pass(.noPill))
        XCTAssertEqual(arrival(request(), pills: false, hub: true), .hold)
        XCTAssertEqual(arrival(request(), pills: true, hub: false), .hold)
        XCTAssertEqual(arrival(request(), pills: true, hub: true), .hold)
    }

    func testOtherPasses() {
        XCTAssertEqual(arrival(request(v: 2)), .pass(.unknownVersion))
        XCTAssertEqual(arrival(request(), setting: false), .pass(.settingOff))
        XCTAssertEqual(arrival(request(tool: "AskUserQuestion")), .pass(.notAPermission))
        XCTAssertEqual(arrival(request(tool: "ExitPlanMode")), .pass(.notAPermission))
        XCTAssertEqual(arrival(request(), held: true), .pass(.alreadyHeld))
    }

    /// Every combination: held exactly when nothing calls for a pass.
    func testHoldsOnlyWhenEveryConditionAllows() {
        let bools = [false, true]
        for v in [1, 2] {
            for tool in ["Bash", "AskUserQuestion"] {
                for owner in [nil, "", terminal] as [String?] {
                    for frontmost in [nil, terminal, cursor] as [String?] {
                        for setting in bools { for held in bools { for pills in bools { for hub in bools {
                            let expectHold = v == 1 && setting && tool == "Bash" && owner == terminal
                                && frontmost != terminal && !held && (pills || hub)
                            let got = arrival(request(tool: tool, owner: owner, v: v), setting: setting,
                                              frontmost: frontmost, held: held, pills: pills, hub: hub)
                            XCTAssertEqual(got == .hold, expectHold,
                                           "v\(v) \(tool) owner=\(owner ?? "nil") front=\(frontmost ?? "nil") setting=\(setting) held=\(held) pills=\(pills) hub=\(hub): \(got)")
                        } } } }
                    }
                }
            }
        }
    }

    // MARK: - Owner becomes frontmost

    func testOwnerComingToTheFrontPassesOnlyItsOwnRequests() {
        XCTAssertTrue(ApprovalRules.ownerIsActive(owner: terminal, active: terminal))
        XCTAssertFalse(ApprovalRules.ownerIsActive(owner: terminal, active: cursor))
        XCTAssertFalse(ApprovalRules.ownerIsActive(owner: terminal, active: "com.apple.Terminal2"))
        XCTAssertFalse(ApprovalRules.ownerIsActive(owner: terminal, active: nil))
        XCTAssertFalse(ApprovalRules.ownerIsActive(owner: nil, active: terminal))
        XCTAssertFalse(ApprovalRules.ownerIsActive(owner: nil, active: nil))
        XCTAssertFalse(ApprovalRules.ownerIsActive(owner: "", active: ""))
    }

    // MARK: - Lifecycle: no pill and no open hub

    func testHeldRequestsNeedThePillOrTheHub() {
        XCTAssertFalse(ApprovalRules.heldRequestsVisible(pillsShown: false, hubOpen: false))
        XCTAssertTrue(ApprovalRules.heldRequestsVisible(pillsShown: true, hubOpen: false))
        XCTAssertTrue(ApprovalRules.heldRequestsVisible(pillsShown: false, hubOpen: true))
    }

    // MARK: - The gate in answer()

    private let oneLine = ApprovalPresentation.allowable(summary: "npm test", fitsOneLine: true)
    private let multiLine = ApprovalPresentation.allowable(summary: "npm ci\nnpm test", fitsOneLine: false)

    func testAllowGoesThroughWhereARowOffersItOnceSettled() {
        XCTAssertEqual(ApprovalRules.answer(allow: true, presentation: oneLine, settled: true), .send)
        XCTAssertEqual(ApprovalRules.answer(allow: true, presentation: multiLine, settled: true), .send,
                       "the row offers Allow even where the pill offers Review")
    }

    func testAllowIsRefusedWhereNoRowOffersIt() {
        for p: ApprovalPresentation in [.openOnly(summary: "Edit page.tsx"),
                                        .allowable(summary: "rm -rf caf\u{E9}", fitsOneLine: true),
                                        .allowable(summary: "a\tb", fitsOneLine: false)] {
            XCTAssertEqual(ApprovalRules.answer(allow: true, presentation: p, settled: true), .allowNotOffered, "\(p)")
        }
    }

    func testAllowIsIgnoredWhileSettling() {
        XCTAssertEqual(ApprovalRules.answer(allow: true, presentation: oneLine, settled: false), .allowSettling)
    }

    func testDenyAlwaysGoesThrough() {
        for settled in [false, true] {
            XCTAssertEqual(ApprovalRules.answer(allow: false, presentation: oneLine, settled: settled), .send)
            XCTAssertEqual(ApprovalRules.answer(allow: false, presentation: .openOnly(summary: "Edit"), settled: settled), .send)
        }
    }

    // MARK: - The 0.5 s settle

    func testStartsSettled() {
        XCTAssertTrue(AllowSettle().isSettled(at: 0))
        XCTAssertTrue(AllowSettle().isSettled(at: 12_345))
    }

    func testRestartWaitsHalfASecond() {
        var settle = AllowSettle()
        settle.restart(at: 100)
        XCTAssertFalse(settle.isSettled(at: 100))
        XCTAssertFalse(settle.isSettled(at: 100.49))
        XCTAssertTrue(settle.isSettled(at: 100.5))
        XCTAssertFalse(settle.isSettled(at: 99), "a reading before the change is not settled")
        XCTAssertFalse(settle.isSettled(at: .nan))
    }

    func testRowAppearingIsNotAMove() {
        var settle = AllowSettle()
        settle.rowReported(id: "r1", top: 200, at: 100)
        XCTAssertTrue(settle.isSettled(at: 100))
    }

    func testRowMovingRestarts() {
        var settle = AllowSettle()
        settle.rowReported(id: "r1", top: 200, at: 100)
        settle.rowReported(id: "r1", top: 240, at: 101)
        XCTAssertFalse(settle.isSettled(at: 101.2))
        XCTAssertTrue(settle.isSettled(at: 101.5))
    }

    func testSubPointJitterIsNotAMoveAndDoesNotDrift() {
        var settle = AllowSettle()
        settle.rowReported(id: "r1", top: 200, at: 100)
        settle.rowReported(id: "r1", top: 200.6, at: 101)
        XCTAssertTrue(settle.isSettled(at: 101))
        // Jitter isn't recorded, so two half-point steps still add up to a move.
        settle.rowReported(id: "r1", top: 201.2, at: 102)
        XCTAssertFalse(settle.isSettled(at: 102))
    }

    func testForgottenRowsReappearWithoutRestarting() {
        var settle = AllowSettle()
        settle.rowReported(id: "r1", top: 200, at: 100)
        settle.forgetRows()   // the hub closed
        settle.rowReported(id: "r1", top: 400, at: 101)
        XCTAssertTrue(settle.isSettled(at: 101))

        settle.forgetRow("r1")   // the request ended
        settle.rowReported(id: "r1", top: 50, at: 102)
        XCTAssertTrue(settle.isSettled(at: 102))
    }

    func testOtherRowsStillCountAfterOneIsForgotten() {
        var settle = AllowSettle()
        settle.rowReported(id: "r1", top: 200, at: 100)
        settle.rowReported(id: "r2", top: 300, at: 100)
        settle.forgetRow("r1")
        settle.rowReported(id: "r2", top: 260, at: 101)
        XCTAssertFalse(settle.isSettled(at: 101))
    }
}
