import XCTest
@testable import ClaudeWidgetCore

/// Sign-in renewal outcomes, spacing, the cross-instance lock and the re-read after
/// it (spec §7). Fake tokens and temporary paths only; nothing here touches the
/// Keychain, the network or `~/.claude/claude-widget`.
final class RenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func credential(_ name: String, expiresIn: TimeInterval = 8 * 3600) -> OAuthCredential {
        OAuthCredential(accessToken: "AAA-\(name)", refreshToken: "RRR-\(name)", expiresAt: now.addingTimeInterval(expiresIn))
    }
    private func body(_ json: String) -> Data { Data(json.utf8) }
    private let documented = #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":28800,"token_type":"Bearer"}"#

    // MARK: - Renewal answers

    func testDocumented200Renews() {
        XCTAssertEqual(TokenRefresh.outcome(status: 200, body: body(documented), now: now),
                       .renewed(OAuthCredential(accessToken: "AAA2", refreshToken: "RRR2",
                                                expiresAt: now.addingTimeInterval(28800))))
        XCTAssertFalse(TokenRefresh.wasSalvaged(body(documented), now: now))
    }

    func testOnlyARefusalReadsAsExpired() {
        for status in [400, 401, 403] {
            let outcome = TokenRefresh.outcome(status: status, body: body(#"{"error":"invalid_grant"}"#), now: now)
            XCTAssertEqual(outcome, .rejected, "\(status)")
            XCTAssertEqual(outcome.failure, .expired, "\(status)")
        }
    }

    func testRateLimitAndServerErrorsReadAsUnavailable() {
        for status in [429, 500, 502, 503, 504, 404, 302, 0] {
            let outcome = TokenRefresh.outcome(status: status, body: body(#"{"error":"overloaded"}"#), now: now)
            XCTAssertEqual(outcome, .inconclusive, "\(status)")
            XCTAssertEqual(outcome.failure, .unavailable, "\(status)")
        }
    }

    func testNon200NeverSalvagesTokensFromItsBody() {
        // Only a 200 means the server issued (and rotated) anything.
        XCTAssertEqual(TokenRefresh.outcome(status: 400, body: body(documented), now: now), .rejected)
        XCTAssertEqual(TokenRefresh.outcome(status: 503, body: body(documented), now: now), .inconclusive)
        XCTAssertEqual(TokenRefresh.outcome(status: 201, body: body(documented), now: now), .inconclusive)
    }

    func test200WithUnexpectedExpirySalvagesBothTokensWithAnHour() {
        let odd = [#"{"access_token":"AAA2","refresh_token":"RRR2"}"#,
                   #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":"28800"}"#,
                   #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":true}"#,
                   #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":0}"#,
                   #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":-5}"#,
                   #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":1e300}"#,
                   #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":null,"surprise":[1]}"#]
        let salvaged = OAuthCredential(accessToken: "AAA2", refreshToken: "RRR2", expiresAt: now.addingTimeInterval(3600))
        for json in odd {
            XCTAssertThrowsError(try TokenRefresh.parseResponse(body(json), now: now), json)
            XCTAssertEqual(TokenRefresh.outcome(status: 200, body: body(json), now: now), .renewed(salvaged), json)
            XCTAssertTrue(TokenRefresh.wasSalvaged(body(json), now: now), json)
        }
    }

    func test200WithoutBothTokensIsNoVerdict() {
        let empty = [#"{"access_token":"AAA2","expires_in":28800}"#,
                     #"{"refresh_token":"RRR2","expires_in":28800}"#,
                     #"{"access_token":"","refresh_token":"RRR2","expires_in":28800}"#,
                     #"{"access_token":"AAA2","refresh_token":7,"expires_in":28800}"#,
                     #"[]"#, "not json"]
        for json in empty {
            XCTAssertEqual(TokenRefresh.outcome(status: 200, body: body(json), now: now), .inconclusive, json)
            XCTAssertFalse(TokenRefresh.wasSalvaged(body(json), now: now), json)
        }
    }

    func testThrownRequestsAreNotSentOnlyWhenProvablyUnsent() {
        XCTAssertEqual(TokenRefresh.outcome(error: URLError(.notConnectedToInternet)), .notSent)
        XCTAssertEqual(TokenRefresh.outcome(error: URLError(.timedOut)), .inconclusive)
        XCTAssertEqual(TokenRefresh.outcome(error: URLError(.networkConnectionLost)), .inconclusive)
        XCTAssertEqual(RenewalOutcome.notSent.failure, .unavailable)
    }

    func testRenewedSignInAlreadyDueIsNoVerdictNotExpired() {
        let fresh = credential("fresh")
        XCTAssertEqual(TokenRefresh.usable(fresh, now: now), .renewed(fresh))
        let due = credential("due", expiresIn: 60)
        XCTAssertEqual(TokenRefresh.usable(due, now: now), .inconclusive)
        XCTAssertEqual(TokenRefresh.usable(due, now: now).failure, .unavailable)
    }

    // MARK: - Spacing

    func testNothingRecordedMeansRenewNow() {
        XCTAssertNil(RenewalSpacing().standing(at: now))
    }

    func testRefusalStandsForTenMinutes() {
        var spacing = RenewalSpacing()
        spacing.record(.rejected, startedAt: now)
        XCTAssertEqual(spacing.standing(at: now.addingTimeInterval(1)), .rejected)
        XCTAssertEqual(spacing.standing(at: now.addingTimeInterval(599)), .rejected)
        XCTAssertNil(spacing.standing(at: now.addingTimeInterval(600)))
    }

    func testSuccessWithinTheWindowNeverReadsAsRejected() {
        var spacing = RenewalSpacing()
        spacing.record(.renewed(credential("new")), startedAt: now)
        XCTAssertEqual(spacing.standing(at: now.addingTimeInterval(120)), .inconclusive)
        XCTAssertEqual(spacing.standing(at: now.addingTimeInterval(120))?.failure, .unavailable)
        XCTAssertNil(spacing.standing(at: now.addingTimeInterval(601)))
    }

    func testNoVerdictStandsAsNoVerdict() {
        var spacing = RenewalSpacing()
        spacing.record(.inconclusive, startedAt: now)
        XCTAssertEqual(spacing.standing(at: now.addingTimeInterval(30)), .inconclusive)
    }

    func testUnsentAttemptGivesTheSlotBackAndKeepsTheEarlierVerdict() {
        var spacing = RenewalSpacing()
        spacing.record(.notSent, startedAt: now)
        XCTAssertNil(spacing.standing(at: now.addingTimeInterval(1)))
        spacing.record(.rejected, startedAt: now)
        spacing.record(.notSent, startedAt: now.addingTimeInterval(60))
        XCTAssertEqual(spacing.standing(at: now.addingTimeInterval(61)), .rejected)
    }

    func testClockSetBackEndsTheWindow() {
        var spacing = RenewalSpacing()
        spacing.record(.rejected, startedAt: now)
        XCTAssertNil(spacing.standing(at: now.addingTimeInterval(-3600)))
    }

    // MARK: - Re-read after the lock

    func testNewerFreshEntryFromAnotherInstanceIsUsedWithoutSending() {
        let mine = credential("old", expiresIn: 60)
        let theirs = credential("renewed-elsewhere")
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .found(theirs), now: now),
                       .use(theirs))
    }

    func testNewerEntryThatIsAlsoDueIsRenewedInsteadOfTheStaleToken() {
        let mine = credential("old", expiresIn: 60)
        let theirs = credential("newer-but-due", expiresIn: 120)
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .found(theirs), now: now),
                       .renew(theirs))
    }

    func testUnchangedEntryRenewsWhatWasHeld() {
        let mine = credential("same", expiresIn: 60)
        var stored = mine
        stored.accessToken = "AAA-other"   // same refresh token: nobody renewed
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .found(stored), now: now),
                       .renew(mine))
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .absent, now: now),
                       .renew(mine))
    }

    func testUnreadableEntrySendsNothing() {
        XCTAssertEqual(RenewalPlan.afterLock(holding: credential("x"), holdingUnsaved: false, entry: .failed(51), now: now),
                       .skip)
    }

    func testUnsavedRenewalIsNeverReplacedByTheOlderEntry() {
        // The entry still holds the sign-in this one replaced (its save failed), so it
        // looks "different and fresh" but its refresh token is dead.
        let unsaved = credential("unsaved", expiresIn: 60)
        for entry: StoredSignIn in [.found(credential("older")), .absent, .failed(51)] {
            XCTAssertEqual(RenewalPlan.afterLock(holding: unsaved, holdingUnsaved: true, entry: entry, now: now),
                           .renew(unsaved))
        }
    }

    // MARK: - Adoption

    func testFingerprintNeverHoldsTheToken() {
        let a = Adoption.fingerprint(refreshToken: "RRR-secret")
        XCTAssertEqual(a, Adoption.fingerprint(refreshToken: "RRR-secret"))
        XCTAssertNotEqual(a, Adoption.fingerprint(refreshToken: "RRR-secret2"))
        XCTAssertEqual(a.count, 64)
        XCTAssertFalse(a.contains("secret"))
    }

    func testAdoptsOnlyANewSignInAfterAFailedRenewal() {
        XCTAssertTrue(Adoption.shouldAdopt(fingerprint: "f1", lastAdopted: "f1", onlyIfNew: false))
        XCTAssertFalse(Adoption.shouldAdopt(fingerprint: "f1", lastAdopted: "f1", onlyIfNew: true))
        XCTAssertTrue(Adoption.shouldAdopt(fingerprint: "f2", lastAdopted: "f1", onlyIfNew: true))
        XCTAssertTrue(Adoption.shouldAdopt(fingerprint: "f1", lastAdopted: nil, onlyIfNew: true))
    }

    // MARK: - Cross-instance lock

    private var dir = ""
    private var lockPath: String { dir + "/run/renew.lock" }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cwl-\(UUID().uuidString.prefix(8))").path
    }

    override func tearDown() {
        if !dir.isEmpty { try? FileManager.default.removeItem(atPath: dir) }
    }

    func testRenewalLockLivesInTheRunDirectory() {
        XCTAssertEqual(WidgetConstants.renewalLock.lastPathComponent, "renew.lock")
        XCTAssertEqual(WidgetConstants.renewalLock.deletingLastPathComponent(), WidgetConstants.runDir)
    }

    func testOneHolderAtATime() throws {
        let a = try XCTUnwrap(FileLock(path: lockPath))
        let b = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(a.tryLock())
        XCTAssertFalse(b.tryLock())
        a.unlock()
        XCTAssertTrue(b.tryLock())
        XCTAssertFalse(a.tryLock())
    }

    func testClosingTheFileReleasesTheLock() throws {
        var a: FileLock? = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(a?.tryLock() == true)
        let b = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertFalse(b.tryLock())
        a = nil
        XCTAssertTrue(b.tryLock())
    }

    func testLockFileAndDirectoryArePrivate() throws {
        _ = try XCTUnwrap(FileLock(path: lockPath))
        let fm = FileManager.default
        XCTAssertEqual((try fm.attributesOfItem(atPath: lockPath)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: dir + "/run")[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSymlinkAtTheLockPathIsRefused() throws {
        try FileManager.default.createDirectory(atPath: dir + "/run", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: lockPath, withDestinationPath: dir + "/elsewhere")
        XCTAssertNil(FileLock(path: lockPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/elsewhere"))
    }

    func testWaitsForTheOtherHolder() async throws {
        let a = try XCTUnwrap(FileLock(path: lockPath))
        let b = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(a.tryLock())
        let release = Task { try? await Task.sleep(for: .milliseconds(300)); a.unlock() }
        let start = ProcessInfo.processInfo.systemUptime
        let took = await b.lock(waitingUpTo: 5, interval: .milliseconds(20))
        XCTAssertTrue(took)
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, 0.25)
        _ = await release.value
    }

    func testGivesUpWhenTheOtherHolderKeepsIt() async throws {
        let a = try XCTUnwrap(FileLock(path: lockPath))
        let b = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(a.tryLock())
        let start = ProcessInfo.processInfo.systemUptime
        let took = await b.lock(waitingUpTo: 0.3, interval: .milliseconds(20))
        XCTAssertFalse(took)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 2)
    }

    /// Another process (`lockf`, which uses flock too) sees this process's lock, and
    /// this process sees its lock until it exits.
    func testLockIsSharedWithOtherProcesses() throws {
        let mine = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(mine.tryLock())
        XCTAssertEqual(try lockf(["-k", "-s", "-t", "0", lockPath, "/usr/bin/true"]).terminationStatus, 75,
                       "EX_TEMPFAIL: held by this process")
        mine.unlock()
        XCTAssertEqual(try lockf(["-k", "-s", "-t", "0", lockPath, "/usr/bin/true"]).terminationStatus, 0)

        let other = try lockf(["-k", "-s", lockPath, "/bin/sleep", "1"], wait: false)
        let deadline = Date().addingTimeInterval(3)
        var refused = false
        while Date() < deadline {
            if mine.tryLock() { mine.unlock() } else { refused = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(refused, "lockf's lock was never seen")
        other.waitUntilExit()
        XCTAssertTrue(mine.tryLock(), "released when the other process exits")
    }

    @discardableResult
    private func lockf(_ arguments: [String], wait: Bool = true) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        p.arguments = arguments
        try p.run()
        if wait { p.waitUntilExit() }
        return p
    }
}
