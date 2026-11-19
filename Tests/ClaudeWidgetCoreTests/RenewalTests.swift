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
    /// The sign-in each renewal answer below replies to.
    private var sent: OAuthCredential { credential("sent", expiresIn: 60) }
    private func outcome(_ status: Int, _ json: String) -> RenewalOutcome {
        TokenRefresh.outcome(status: status, body: body(json), sent: sent, now: now)
    }

    // MARK: - Renewal answers

    func testDocumented200Renews() {
        XCTAssertEqual(outcome(200, documented),
                       .renewed(OAuthCredential(accessToken: "AAA2", refreshToken: "RRR2",
                                                expiresAt: now.addingTimeInterval(28800))))
        XCTAssertFalse(TokenRefresh.wasSalvaged(body(documented), sent: sent, now: now))
    }

    func testOnlyARefusalReadsAsExpired() {
        for status in [400, 401, 403] {
            let outcome = self.outcome(status, #"{"error":"invalid_grant"}"#)
            XCTAssertEqual(outcome, .rejected, "\(status)")
            XCTAssertEqual(outcome.failure, .expired, "\(status)")
        }
    }

    func testRateLimitAndServerErrorsReadAsUnavailable() {
        for status in [429, 500, 502, 503, 504, 404, 302, 0] {
            let outcome = self.outcome(status, #"{"error":"overloaded"}"#)
            XCTAssertEqual(outcome, .inconclusive, "\(status)")
            XCTAssertEqual(outcome.failure, .unavailable, "\(status)")
        }
    }

    func testNon200NeverSalvagesTokensFromItsBody() {
        // Only a 200 means the server issued (and rotated) anything.
        XCTAssertEqual(outcome(400, documented), .rejected)
        XCTAssertEqual(outcome(503, documented), .inconclusive)
        XCTAssertEqual(outcome(201, documented), .inconclusive)
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
            XCTAssertEqual(outcome(200, json), .renewed(salvaged), json)
            XCTAssertTrue(TokenRefresh.wasSalvaged(body(json), sent: sent, now: now), json)
        }
    }

    func test200WithOnlyAnAccessTokenKeepsTheRefreshTokenSent() {
        // No rotation: the refresh token sent is still the live one.
        for json in [#"{"access_token":"AAA2","expires_in":28800}"#,
                     #"{"access_token":"AAA2","refresh_token":"","expires_in":28800}"#,
                     #"{"access_token":"AAA2","refresh_token":7}"#] {
            XCTAssertEqual(outcome(200, json),
                           .renewed(OAuthCredential(accessToken: "AAA2", refreshToken: sent.refreshToken,
                                                    expiresAt: now.addingTimeInterval(3600))), json)
            XCTAssertTrue(TokenRefresh.wasSalvaged(body(json), sent: sent, now: now), json)
        }
    }

    func test200WithOnlyARefreshTokenSavesItButGivesNoVerdict() throws {
        // The refresh token sent is spent and this is its replacement: it must be
        // saved, beside an access token marked expired, so it's renewed next.
        for json in [#"{"refresh_token":"RRR2","expires_in":28800}"#,
                     #"{"access_token":"","refresh_token":"RRR2","expires_in":28800}"#,
                     #"{"access_token":null,"refresh_token":"RRR2"}"#] {
            guard case .renewed(let kept) = outcome(200, json) else { return XCTFail(json) }
            XCTAssertEqual(kept.refreshToken, "RRR2", json)
            XCTAssertEqual(kept.expiresAt, .distantPast, json)
            XCTAssertEqual(TokenRefresh.usable(kept, now: now), .inconclusive, "no verdict this poll: \(json)")
        }
    }

    func test200WithNoTokensIsNoVerdict() {
        for json in [#"{"expires_in":28800}"#, #"{"access_token":"","refresh_token":""}"#,
                     #"{"access_token":5,"refresh_token":false}"#, #"[]"#, "not json", ""] {
            XCTAssertEqual(outcome(200, json), .inconclusive, json)
            XCTAssertFalse(TokenRefresh.wasSalvaged(body(json), sent: sent, now: now), json)
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

    // MARK: - Spacing (monotonic time)

    private let t0 = ContinuousClock.now

    func testNothingRecordedMeansRenewNow() {
        XCTAssertNil(RenewalSpacing().standing(at: t0))
    }

    func testRefusalStandsForTenMinutes() {
        var spacing = RenewalSpacing()
        spacing.record(.rejected, startedAt: t0)
        XCTAssertEqual(spacing.standing(at: t0 + .seconds(1)), .rejected)
        XCTAssertEqual(spacing.standing(at: t0 + .seconds(599)), .rejected)
        XCTAssertNil(spacing.standing(at: t0 + .seconds(600)))
    }

    func testSuccessWithinTheWindowNeverReadsAsRejected() {
        var spacing = RenewalSpacing()
        spacing.record(.renewed(credential("new")), startedAt: t0)
        XCTAssertEqual(spacing.standing(at: t0 + .seconds(120)), .inconclusive)
        XCTAssertEqual(spacing.standing(at: t0 + .seconds(120))?.failure, .unavailable)
        XCTAssertNil(spacing.standing(at: t0 + .seconds(601)))
    }

    func testNoVerdictStandsAsNoVerdict() {
        var spacing = RenewalSpacing()
        spacing.record(.inconclusive, startedAt: t0)
        XCTAssertEqual(spacing.standing(at: t0 + .seconds(30)), .inconclusive)
    }

    func testUnsentAttemptGivesTheSlotBackAndKeepsTheEarlierVerdict() {
        var spacing = RenewalSpacing()
        spacing.record(.notSent, startedAt: t0)
        XCTAssertNil(spacing.standing(at: t0 + .seconds(1)))
        spacing.record(.rejected, startedAt: t0)
        spacing.record(.notSent, startedAt: t0 + .seconds(60))
        XCTAssertEqual(spacing.standing(at: t0 + .seconds(61)), .rejected)
    }

    func testTheWindowOnlyEndsWhenTenMinutesHavePassed() {
        // No wall-clock reading is involved, so a clock set back (or forward)
        // can't end the window early; a reading from before the attempt is inside it.
        var spacing = RenewalSpacing()
        spacing.record(.rejected, startedAt: t0)
        XCTAssertEqual(spacing.standing(at: t0 - .seconds(3600)), .rejected)
    }

    // MARK: - Re-read after the lock

    func testNewerFreshEntryFromAnotherInstanceIsUsedWithoutSending() {
        let mine = credential("old", expiresIn: 60)
        let theirs = credential("renewed-elsewhere")
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .found(theirs), spent: nil, now: now),
                       .use(theirs))
    }

    func testNewerEntryThatIsAlsoDueIsRenewedInsteadOfTheStaleToken() {
        let mine = credential("old", expiresIn: 60)
        let theirs = credential("newer-but-due", expiresIn: 120)
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .found(theirs), spent: nil, now: now),
                       .renew(theirs))
    }

    func testUnchangedEntryRenewsWhatWasHeld() {
        let mine = credential("same", expiresIn: 60)
        var stored = mine
        stored.accessToken = "AAA-other"   // same refresh token: nobody renewed
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .found(stored), spent: nil, now: now),
                       .renew(mine))
        XCTAssertEqual(RenewalPlan.afterLock(holding: mine, holdingUnsaved: false, entry: .absent, spent: nil, now: now),
                       .renew(mine))
    }

    func testUnreadableEntrySendsNothing() {
        XCTAssertEqual(RenewalPlan.afterLock(holding: credential("x"), holdingUnsaved: false, entry: .failed(51), spent: nil, now: now),
                       .skip)
    }

    func testUnsavedRenewalIsNeverReplacedByTheOlderEntry() {
        // The entry still holds the sign-in this one replaced (its save failed), so it
        // looks "different and fresh" but its refresh token is dead.
        let unsaved = credential("unsaved", expiresIn: 60)
        for entry: StoredSignIn in [.found(credential("older")), .absent, .failed(51)] {
            XCTAssertEqual(RenewalPlan.afterLock(holding: unsaved, holdingUnsaved: true, entry: entry, spent: nil, now: now),
                           .renew(unsaved))
        }
    }

    func testSpentTokenIsNeverSent() {
        // Another instance renewed "held" (the server rotated it) but its save
        // failed, so the entry still holds it.
        let held = credential("held", expiresIn: 60)
        let marker = Adoption.fingerprint(refreshToken: held.refreshToken)
        XCTAssertEqual(RenewalPlan.afterLock(holding: held, holdingUnsaved: false, entry: .found(held), spent: marker, now: now),
                       .spent)
        XCTAssertEqual(RenewalPlan.afterLock(holding: held, holdingUnsaved: false, entry: .absent, spent: marker, now: now),
                       .spent)
        // The entry's own due token, when it's the spent one.
        let stored = credential("stored", expiresIn: 60)
        XCTAssertEqual(RenewalPlan.afterLock(holding: credential("older"), holdingUnsaved: false, entry: .found(stored),
                                             spent: Adoption.fingerprint(refreshToken: stored.refreshToken), now: now),
                       .spent)
    }

    func testSpentMarkerBlocksOnlyThatToken() {
        let held = credential("held", expiresIn: 60)
        let other = Adoption.fingerprint(refreshToken: "RRR-someone-else")
        XCTAssertEqual(RenewalPlan.afterLock(holding: held, holdingUnsaved: false, entry: .found(held), spent: other, now: now),
                       .renew(held))
        XCTAssertEqual(RenewalPlan.afterLock(holding: held, holdingUnsaved: false, entry: .found(held), spent: "", now: now),
                       .renew(held))
        // A marker never stops using a fresh sign-in another instance saved.
        let fresh = credential("fresh")
        XCTAssertEqual(RenewalPlan.afterLock(holding: held, holdingUnsaved: false, entry: .found(fresh),
                                             spent: Adoption.fingerprint(refreshToken: held.refreshToken), now: now),
                       .use(fresh))
        // Nor an unsaved renewal, whose token is the live one.
        let unsaved = credential("unsaved", expiresIn: 60)
        XCTAssertEqual(RenewalPlan.afterLock(holding: unsaved, holdingUnsaved: true, entry: .found(held),
                                             spent: Adoption.fingerprint(refreshToken: held.refreshToken), now: now),
                       .renew(unsaved))
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

    func testWaitStopsWhenToldToGiveUp() async throws {
        let a = try XCTUnwrap(FileLock(path: lockPath))
        let b = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(a.tryLock())
        let stop = Flag()
        let start = ProcessInfo.processInfo.systemUptime
        Task { try? await Task.sleep(for: .milliseconds(100)); stop.set() }
        let took = await b.lock(waitingUpTo: 10, interval: .milliseconds(20), giveUpIf: { stop.isSet })
        XCTAssertFalse(took)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2, "stopped well before the 10 s timeout")
        // Told to give up before trying: not taken even though it's free.
        a.unlock()
        let refused = await b.lock(waitingUpTo: 1, giveUpIf: { true })
        XCTAssertFalse(refused)
        XCTAssertTrue(b.tryLock(), "never taken by the refused attempt")
    }

    func testCancelledWaitReturnsAtOnce() async throws {
        let a = try XCTUnwrap(FileLock(path: lockPath))
        let b = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(a.tryLock())
        let start = ProcessInfo.processInfo.systemUptime
        let wait = Task { await b.lock(waitingUpTo: 10, interval: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        wait.cancel()
        let took = await wait.value
        XCTAssertFalse(took)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2, "no spinning until the deadline")
    }

    func testContentsAreReplacedWhole() throws {
        let a = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(a.tryLock())
        XCTAssertEqual(a.contents(), "")
        XCTAssertTrue(a.replaceContents(with: String(repeating: "a", count: 64)))
        XCTAssertTrue(a.replaceContents(with: "bb"))
        XCTAssertEqual(a.contents(), "bb", "the longer old contents are cut")
        a.unlock()
        let b = try XCTUnwrap(FileLock(path: lockPath))
        XCTAssertTrue(b.tryLock())
        XCTAssertEqual(b.contents(), "bb", "kept in the file for the next holder")
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

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
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
