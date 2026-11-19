import XCTest
@testable import ClaudeWidgetCore

/// The renewal sequence exactly as UsageMonitor runs it: spacing, the quit /
/// Limits-off guard, the re-read after the lock, the spent-token marker and a
/// failed save. Fake tokens, a fake Keychain entry and a fake token endpoint; the
/// lock is a real file in a temporary directory.
@MainActor
final class SignInRenewerTests: XCTestCase {
    typealias Reply = Result<(body: Data, status: Int), Error>

    /// One copy of the app: its view of the widget's Keychain entry, and what it sent and saved.
    @MainActor
    final class Instance {
        var entry: StoredSignIn = .absent
        var replies: [Reply] = []
        var maySend = true
        var saveWorks = true
        /// Per-save results, used up in order before `saveWorks` applies.
        var saveResults: [Bool] = []
        var sendDelay: Duration?
        /// Refresh tokens sent, in order.
        var sent: [String] = []
        var saved: [OAuthCredential] = []
        var duringRead: (() -> Void)?
        var duringSave: (() -> Void)?
        let lockPath: String

        init(lockPath: String) { self.lockPath = lockPath }

        lazy var renewer = SignInRenewer(
            lockPath: lockPath, lockWait: 5, lockInterval: .milliseconds(10),
            maySend: { [unowned self] in self.maySend },
            readOwn: { [unowned self] in
                self.duringRead?()
                return self.entry
            },
            send: { [unowned self] request in
                XCTAssertEqual(request.url, TokenRefresh.url)
                let fields = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
                self.sent.append(fields?["refresh_token"] ?? "?")
                if let delay = self.sendDelay { try? await Task.sleep(for: delay) }
                guard !self.replies.isEmpty else {
                    XCTFail("unexpected renewal request")
                    throw URLError(.badServerResponse)
                }
                return try self.replies.removeFirst().get()
            },
            save: { [unowned self] credential in
                self.duringSave?()
                self.saved.append(credential)
                let works = self.saveResults.isEmpty ? self.saveWorks : self.saveResults.removeFirst()
                if works { self.entry = .found(credential) }
                return works
            })
    }

    private func signIn(_ name: String, expiresIn: TimeInterval = 60) -> OAuthCredential {
        OAuthCredential(accessToken: "AAA-\(name)", refreshToken: "RRR-\(name)", expiresAt: Date().addingTimeInterval(expiresIn))
    }

    private func tokens(_ access: String?, _ refresh: String?) -> Reply {
        var fields: [String: Any] = ["expires_in": 28800]
        if let access { fields["access_token"] = access }
        if let refresh { fields["refresh_token"] = refresh }
        return .success((try! JSONSerialization.data(withJSONObject: fields), 200))
    }

    private func status(_ code: Int) -> Reply { .success((Data(#"{"error":"x"}"#.utf8), code)) }

    /// A fresh lock path in its own temporary directory, removed after the test.
    private func newLockPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cwr-\(UUID().uuidString.prefix(8))").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir + "/run/renew.lock"
    }

    /// Makes the lock file's marker look written `ago` seconds back.
    private func backdateMarker(at path: String, by ago: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: path)
    }

    /// Instance A renews `token` and gets a rotated one, but its save fails: the
    /// entry still holds `token`, now marked spent. Returns A.
    private func renewedButUnsaved(_ token: OAuthCredential, at path: String, into next: String) async -> Instance {
        let a = Instance(lockPath: path)
        a.entry = .found(token)
        a.saveWorks = false
        a.replies = [tokens("AAA-\(next)", "RRR-\(next)")]
        _ = await a.renewer.renew(token)
        XCTAssertEqual(a.renewer.unsaved?.refreshToken, "RRR-\(next)")
        return a
    }

    /// The spent-token marker, as the next holder of the lock reads it.
    private func marker(at path: String) throws -> String {
        let lock = try XCTUnwrap(FileLock(path: path))
        XCTAssertTrue(lock.tryLock(), "the lock is free between renewals")
        return lock.contents()
    }

    // MARK: - Renew, save, use

    func testRenewsSavesThenUses() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.replies = [tokens("AAA-new", "RRR-new")]
        let outcome = await a.renewer.renew(old)
        guard case .renewed(let new) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(new.refreshToken, "RRR-new")
        XCTAssertEqual(a.sent, ["RRR-old"])
        XCTAssertEqual(a.saved, [new])
        XCTAssertNil(a.renewer.unsaved)
        XCTAssertFalse(a.renewer.renewing)
    }

    func testOneRenewalInFlight() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.replies = [tokens("AAA-new", "RRR-new")]
        a.sendDelay = .milliseconds(200)
        async let first = a.renewer.renew(old)
        async let second = a.renewer.renew(old)
        let (x, y) = await (first, second)
        XCTAssertEqual(x, y)
        XCTAssertEqual(a.sent, ["RRR-old"])
    }

    // MARK: - Spacing is recorded

    func testASecondRenewalWithinTenMinutesIsNotSent() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.replies = [tokens("AAA-new", "RRR-new")]
        guard case .renewed(let new) = await a.renewer.renew(old) else { return XCTFail() }
        let again = await a.renewer.renew(new)
        XCTAssertEqual(again, .recentlyRenewed, "a renewal that worked never reads as refused")
        XCTAssertEqual(again.failure(afterFeedRefusal: true), .expired, "the feed refused it again: same verdict")
        XCTAssertEqual(again.failure(afterFeedRefusal: false), .unavailable)
        XCTAssertEqual(a.sent, ["RRR-old"])
    }

    func testARefusalStandsWithoutResending() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.replies = [status(400)]
        let first = await a.renewer.renew(old)
        let second = await a.renewer.renew(old)
        XCTAssertEqual(first, .rejected)
        XCTAssertEqual(second, .rejected)
        XCTAssertEqual(a.sent, ["RRR-old"])
    }

    func testAnUnsentRequestGivesTheSlotBack() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.replies = [.failure(URLError(.notConnectedToInternet)), tokens("AAA-new", "RRR-new")]
        let first = await a.renewer.renew(old)
        XCTAssertEqual(first, .notSent)
        guard case .renewed = await a.renewer.renew(old) else { return XCTFail() }
        XCTAssertEqual(a.sent, ["RRR-old", "RRR-old"])
    }

    // MARK: - Quitting or Limits off: nothing is sent

    func testNothingIsSentWhileQuittingOrLimitsOff() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.maySend = false
        let outcome = await a.renewer.renew(old)
        XCTAssertEqual(outcome, .notSent)
        XCTAssertEqual(a.sent, [])
        // Nothing was sent, so the 10-minute slot is still free.
        a.maySend = true
        a.replies = [tokens("AAA-new", "RRR-new")]
        guard case .renewed = await a.renewer.renew(old) else { return XCTFail() }
        XCTAssertEqual(a.sent, ["RRR-old"])
    }

    func testQuittingWhileTheEntryIsReadSendsNothing() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.duringRead = { a.maySend = false }
        let outcome = await a.renewer.renew(old)
        XCTAssertEqual(outcome, .notSent)
        XCTAssertEqual(a.sent, [])
    }

    func testQuittingStopsTheWaitForAnotherInstancesLock() async throws {
        let path = newLockPath()
        let other = try XCTUnwrap(FileLock(path: path))
        XCTAssertTrue(other.tryLock())
        let a = Instance(lockPath: path)
        let old = signIn("old")
        a.entry = .found(old)
        let start = ProcessInfo.processInfo.systemUptime
        let renewal = Task { await a.renewer.renew(old) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(a.renewer.renewing, "quit would wait for this")
        a.maySend = false
        let outcome = await renewal.value
        XCTAssertEqual(outcome, .notSent)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2, "gave up, not the 5 s lock wait")
        XCTAssertEqual(a.sent, [])
    }

    /// `bundle.sh --install`: the installed copy holds the lock, quit begins, then the lock frees.
    func testALockFreedAfterQuittingStartsSendsNothing() async throws {
        let path = newLockPath()
        let other = try XCTUnwrap(FileLock(path: path))
        XCTAssertTrue(other.tryLock())
        let a = Instance(lockPath: path)
        let old = signIn("old")
        a.entry = .found(old)
        let renewal = Task { await a.renewer.renew(old) }
        try await Task.sleep(for: .milliseconds(100))
        a.maySend = false
        other.unlock()
        let outcome = await renewal.value
        XCTAssertEqual(outcome, .notSent)
        XCTAssertEqual(a.sent, [])
    }

    // MARK: - The entry, read again under the lock

    func testWaitsForAnotherInstanceThenUsesItsRenewal() async throws {
        let path = newLockPath()
        let other = try XCTUnwrap(FileLock(path: path))
        XCTAssertTrue(other.tryLock())
        let a = Instance(lockPath: path)
        let old = signIn("old")
        a.entry = .found(old)
        let renewal = Task { await a.renewer.renew(old) }
        try await Task.sleep(for: .milliseconds(100))
        let theirs = signIn("theirs", expiresIn: 8 * 3600)
        a.entry = .found(theirs)   // the other instance renewed and saved
        other.unlock()
        let outcome = await renewal.value
        XCTAssertEqual(outcome, .renewed(theirs))
        XCTAssertEqual(a.sent, [])
    }

    func testUnreadableEntrySendsNothing() async {
        let a = Instance(lockPath: newLockPath())
        a.entry = .failed(51)
        let outcome = await a.renewer.renew(signIn("old"))
        XCTAssertEqual(outcome, .notSent)
        XCTAssertEqual(a.sent, [])
    }

    func testTheUnsavedRenewalIsTheOneRenewed() async {
        // Its save failed, so the entry still holds what it replaced: different
        // from it, and looking fresh, but spent.
        let a = Instance(lockPath: newLockPath())
        let unsaved = signIn("unsaved")
        a.renewer.unsaved = unsaved
        a.entry = .found(signIn("replaced", expiresIn: 8 * 3600))
        a.replies = [tokens("AAA-next", "RRR-next")]
        guard case .renewed = await a.renewer.renew(unsaved) else { return XCTFail() }
        XCTAssertEqual(a.sent, ["RRR-unsaved"])
    }

    // MARK: - A failed save

    func testAFailedSaveKeepsTheRenewalAsUnsaved() async {
        let a = Instance(lockPath: newLockPath())
        let old = signIn("old")
        a.entry = .found(old)
        a.saveWorks = false
        a.replies = [tokens("AAA-new", "RRR-new")]
        guard case .renewed(let new) = await a.renewer.renew(old) else { return XCTFail() }
        XCTAssertEqual(a.renewer.unsaved, new)
        XCTAssertEqual(a.entry, .found(old))
    }

    func testASavedRenewalClearsTheUnsavedOne() async {
        let a = Instance(lockPath: newLockPath())
        let unsaved = signIn("unsaved")
        a.renewer.unsaved = unsaved
        a.entry = .found(signIn("replaced"))
        a.replies = [tokens("AAA-next", "RRR-next")]
        guard case .renewed = await a.renewer.renew(unsaved) else { return XCTFail() }
        XCTAssertNil(a.renewer.unsaved)
    }

    // MARK: - The spent-token marker

    /// §15's incident shape: A renews R1 and gets R2, but can't save it, so the entry
    /// still says R1. B must not send R1.
    func testASpentTokenIsNotSentByAnotherInstance() async throws {
        let path = newLockPath()
        let r1 = signIn("r1")
        let a = Instance(lockPath: path)
        a.entry = .found(r1)
        a.saveWorks = false
        a.replies = [tokens("AAA-r2", "RRR-r2")]
        var markerAtSave: String?
        a.duringSave = { markerAtSave = (FileLock(path: path)?.contents()) }
        guard case .renewed = await a.renewer.renew(r1) else { return XCTFail() }
        XCTAssertEqual(a.renewer.unsaved?.refreshToken, "RRR-r2")
        XCTAssertEqual(markerAtSave, Adoption.fingerprint(refreshToken: "RRR-r1"), "marked before the save")

        let b = Instance(lockPath: path)
        b.entry = .found(r1)
        b.replies = [status(400)]
        let outcome = await b.renewer.renew(r1)
        XCTAssertEqual(outcome, .notSent, "no verdict")
        XCTAssertEqual(outcome.failure(afterFeedRefusal: true), .unavailable, "never Sign-in expired")
        XCTAssertEqual(b.sent, [])

        let stored = try marker(at: path)
        XCTAssertEqual(stored, Adoption.fingerprint(refreshToken: "RRR-r1"))
        XCTAssertFalse(stored.contains("RRR") || stored.contains("AAA"), "a fingerprint, never a token")
    }

    func testTheMarkerDoesNotBlockADifferentToken() async {
        let path = newLockPath()
        let a = Instance(lockPath: path)
        a.entry = .found(signIn("r1"))
        a.saveWorks = false
        a.replies = [tokens("AAA-r2", "RRR-r2")]
        _ = await a.renewer.renew(signIn("r1"))

        let c = Instance(lockPath: path)
        let r9 = signIn("r9")
        c.entry = .found(r9)
        c.replies = [tokens("AAA-r10", "RRR-r10")]
        guard case .renewed = await c.renewer.renew(r9) else { return XCTFail() }
        XCTAssertEqual(c.sent, ["RRR-r9"])
    }

    func testNoMarkerUnlessTheServerRotatedTheToken() async throws {
        let cases: [(String, Reply)] = [
            ("never sent", .failure(URLError(.notConnectedToInternet))),
            ("timed out", .failure(URLError(.timedOut))),
            ("refused", status(400)),
            ("server error", status(503)),
            ("rate limited", status(429)),
            ("200 without tokens", tokens(nil, nil)),
            ("200 without rotation", tokens("AAA-new", nil)),
        ]
        for (label, reply) in cases {
            let path = newLockPath()
            let r1 = signIn("r1")
            let a = Instance(lockPath: path)
            a.entry = .found(r1)
            a.replies = [reply]
            _ = await a.renewer.renew(r1)
            XCTAssertEqual(a.sent, ["RRR-r1"], label)
            XCTAssertEqual(try marker(at: path), "", label)

            // So another instance may still send it.
            let b = Instance(lockPath: path)
            b.entry = .found(r1)
            b.replies = [tokens("AAA-r2", "RRR-r2")]
            _ = await b.renewer.renew(r1)
            XCTAssertEqual(b.sent, ["RRR-r1"], label)
        }
    }

    func testARefreshOnlyAnswerIsSavedMarkedAndGivesNoVerdict() async throws {
        let path = newLockPath()
        let a = Instance(lockPath: path)
        let r1 = signIn("r1")
        a.entry = .found(r1)
        a.replies = [tokens(nil, "RRR-r2")]
        let outcome = await a.renewer.renew(r1)
        XCTAssertEqual(outcome, .inconclusive)
        XCTAssertEqual(a.saved.map(\.refreshToken), ["RRR-r2"], "the live refresh token is kept")
        XCTAssertEqual(try marker(at: path), Adoption.fingerprint(refreshToken: "RRR-r1"))
    }

    // MARK: - A marker left behind

    /// A renewed R1 → R2, marked R1, couldn't save R2, then quit or crashed: R2 is
    /// gone and the entry's R1 is dead. Once the marker is old that reads "expired",
    /// so a fresh /login can be adopted, without sending R1.
    func testAnOldMarkerReadsAsExpiredWithoutSending() async throws {
        let path = newLockPath()
        let r1 = signIn("r1")
        _ = await renewedButUnsaved(r1, at: path, into: "r2")
        try backdateMarker(at: path, by: SpentMarker.lifetime + 60)

        let relaunched = Instance(lockPath: path)
        relaunched.entry = .found(r1)
        let outcome = await relaunched.renewer.renew(r1)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(outcome.failure(afterFeedRefusal: false), .expired)
        XCTAssertEqual(relaunched.sent, [])

        // Nothing was sent, so the 10-minute spacing is untouched: a /login adopted
        // next renews at once.
        let login = signIn("login")
        relaunched.entry = .found(login)
        relaunched.replies = [tokens("AAA-l2", "RRR-l2")]
        guard case .renewed = await relaunched.renewer.renew(login) else { return XCTFail() }
        XCTAssertEqual(relaunched.sent, ["RRR-login"])
    }

    func testAYoungMarkerStillOnlyHoldsBack() async throws {
        let path = newLockPath()
        let r1 = signIn("r1")
        _ = await renewedButUnsaved(r1, at: path, into: "r2")
        try backdateMarker(at: path, by: SpentMarker.lifetime - 120)

        let b = Instance(lockPath: path)
        b.entry = .found(r1)
        let outcome = await b.renewer.renew(r1)
        XCTAssertEqual(outcome, .notSent)
        XCTAssertEqual(outcome.failure(afterFeedRefusal: true), .unavailable, "not expired while A may still save")
        XCTAssertEqual(b.sent, [])
    }

    func testAnOldMarkerOnAnotherTokenDoesNotBlock() async throws {
        let path = newLockPath()
        _ = await renewedButUnsaved(signIn("r1"), at: path, into: "r2")
        try backdateMarker(at: path, by: 6 * 3600)

        let c = Instance(lockPath: path)
        let r9 = signIn("r9")
        c.entry = .found(r9)
        c.replies = [tokens("AAA-r10", "RRR-r10")]
        guard case .renewed = await c.renewer.renew(r9) else { return XCTFail() }
        XCTAssertEqual(c.sent, ["RRR-r9"])
    }

    // MARK: - Renewing an unsaved sign-in keeps the marker

    func testRenewingAnUnsavedSignInKeepsTheEntrysTokenMarked() async throws {
        let path = newLockPath()
        let r1 = signIn("r1")
        let a = await renewedButUnsaved(r1, at: path, into: "r2")
        // A, a poll later (past the spacing window), renews its unsaved R2; that
        // save fails too.
        let later = Instance(lockPath: path)
        later.renewer.unsaved = a.renewer.unsaved
        later.entry = .found(r1)
        later.saveWorks = false
        later.replies = [tokens("AAA-r3", "RRR-r3")]
        _ = await later.renewer.renew(try XCTUnwrap(a.renewer.unsaved))
        XCTAssertEqual(later.sent, ["RRR-r2"])
        XCTAssertEqual(try marker(at: path), Adoption.fingerprint(refreshToken: "RRR-r1"),
                       "R2 was never in the entry; R1 is what must stay marked")

        let b = Instance(lockPath: path)
        b.entry = .found(r1)
        let outcome = await b.renewer.renew(r1)
        XCTAssertEqual(outcome, .notSent)
        XCTAssertEqual(b.sent, [])
    }

    // MARK: - Retrying a failed save, alongside a renewal

    /// P1's retry-save of U failed, so P1 renewed U and that renewal T is still in
    /// flight when P2 (a replaced poll loop) retries the save. T's save works.
    func testARetrySaveWaitsForTheRenewalAndNeverOverwritesIt() async throws {
        let a = Instance(lockPath: newLockPath())
        let u = signIn("u")
        a.renewer.unsaved = u
        a.entry = .found(signIn("r1"))
        a.replies = [tokens("AAA-r3", "RRR-r3")]
        a.sendDelay = .milliseconds(200)
        let renewal = Task { await a.renewer.renew(u) }
        try await Task.sleep(for: .milliseconds(50))
        let pending = await a.renewer.retryUnsaved()
        _ = await renewal.value
        XCTAssertNil(pending, "nothing pending: the entry is current")
        XCTAssertEqual(a.saved.map(\.refreshToken), ["RRR-r3"], "U is never saved over R3")
        guard case .found(let stored) = a.entry else { return XCTFail() }
        XCTAssertEqual(stored.refreshToken, "RRR-r3")
        XCTAssertNil(a.renewer.unsaved)
    }

    /// The other ordering: T's own save fails, so R3 is what's pending when P2 retries.
    func testARetrySaveAfterAFailedRenewalSaveSavesTheNewerSignIn() async throws {
        let a = Instance(lockPath: newLockPath())
        let u = signIn("u")
        a.renewer.unsaved = u
        a.entry = .found(signIn("r1"))
        a.replies = [tokens("AAA-r3", "RRR-r3")]
        a.sendDelay = .milliseconds(200)
        a.saveResults = [false]
        let renewal = Task { await a.renewer.renew(u) }
        try await Task.sleep(for: .milliseconds(50))
        let pending = await a.renewer.retryUnsaved()
        _ = await renewal.value
        XCTAssertEqual(pending?.refreshToken, "RRR-r3")
        XCTAssertEqual(a.saved.map(\.refreshToken), ["RRR-r3", "RRR-r3"], "U is never saved; R3 is retried")
        XCTAssertNil(a.renewer.unsaved)
    }

    func testARetrySaveThatFailsKeepsItPending() async {
        let a = Instance(lockPath: newLockPath())
        let u = signIn("u")
        a.renewer.unsaved = u
        a.saveWorks = false
        let pending = await a.renewer.retryUnsaved()
        XCTAssertEqual(pending, u, "used this poll")
        XCTAssertEqual(a.renewer.unsaved, u)
        let none = Instance(lockPath: newLockPath())
        let nothing = await none.renewer.retryUnsaved()
        XCTAssertNil(nothing)
        XCTAssertEqual(none.saved, [])
    }

    // MARK: - Adopting Claude Code's sign-in, alongside a renewal

    /// The poll used Claude Code's sign-in without saving it (entry absent) and is
    /// renewing it; P2 found the entry absent and adopts the same sign-in, which
    /// the renewal has just spent.
    func testAnAdoptionWaitsForTheRenewalAndNeverOverwritesIt() async throws {
        let a = Instance(lockPath: newLockPath())
        let theirs = signIn("cc")
        a.entry = .absent
        a.replies = [tokens("AAA-r3", "RRR-r3")]
        a.sendDelay = .milliseconds(200)
        let renewal = Task { await a.renewer.renew(theirs) }
        try await Task.sleep(for: .milliseconds(50))
        let adoption = await a.renewer.adopt(theirs, replacing: nil)
        _ = await renewal.value
        guard case .found(let r3) = a.entry else { return XCTFail() }
        XCTAssertEqual(r3.refreshToken, "RRR-r3")
        XCTAssertEqual(adoption, .superseded(r3))
        XCTAssertEqual(a.saved.map(\.refreshToken), ["RRR-r3"], "the spent sign-in is never saved over R3")
    }

    func testAnAdoptionAfterAFailedRenewalSaveYieldsTheUnsavedSignIn() async throws {
        let a = Instance(lockPath: newLockPath())
        let theirs = signIn("cc")
        a.entry = .absent
        a.replies = [tokens("AAA-r3", "RRR-r3")]
        a.sendDelay = .milliseconds(200)
        a.saveResults = [false]
        let renewal = Task { await a.renewer.renew(theirs) }
        try await Task.sleep(for: .milliseconds(50))
        let adoption = await a.renewer.adopt(theirs, replacing: nil)
        _ = await renewal.value
        let r3 = try XCTUnwrap(a.renewer.unsaved)
        XCTAssertEqual(r3.refreshToken, "RRR-r3")
        XCTAssertEqual(adoption, .superseded(r3))
        XCTAssertEqual(a.saved.map(\.refreshToken), ["RRR-r3"])
        XCTAssertEqual(a.entry, .absent)
    }

    func testASpentSignInIsNeverAdopted() async throws {
        let path = newLockPath()
        let theirs = signIn("cc")
        _ = await renewedButUnsaved(theirs, at: path, into: "r2")
        let relaunched = Instance(lockPath: path)
        relaunched.entry = .absent
        let adoption = await relaunched.renewer.adopt(theirs, replacing: nil)
        XCTAssertEqual(adoption, .spent)
        XCTAssertEqual(relaunched.saved, [])
    }

    func testAnAdoptionReplacesOnlyTheSignInTheCallerSaw() async {
        let r1 = signIn("r1")
        let login = signIn("login", expiresIn: 8 * 3600)

        let a = Instance(lockPath: newLockPath())
        a.entry = .found(r1)
        let saved = await a.renewer.adopt(login, replacing: r1)
        XCTAssertEqual(saved, .saved)
        XCTAssertEqual(a.entry, .found(login))

        let b = Instance(lockPath: newLockPath())
        let saved2 = await b.renewer.adopt(login, replacing: nil)
        XCTAssertEqual(saved2, .saved, "nothing there to lose")

        let c = Instance(lockPath: newLockPath())
        c.renewer.unsaved = r1
        c.entry = .found(signIn("replaced"))
        let saved3 = await c.renewer.adopt(login, replacing: r1)
        XCTAssertEqual(saved3, .saved)
        XCTAssertNil(c.renewer.unsaved, "the unsaved sign-in it replaced is dropped")

        // Something else is there now: it's newer than what the caller saw.
        let d = Instance(lockPath: newLockPath())
        let r9 = signIn("r9")
        d.entry = .found(r9)
        let superseded = await d.renewer.adopt(login, replacing: r1)
        XCTAssertEqual(superseded, .superseded(r9))
        XCTAssertEqual(d.saved, [])

        let e = Instance(lockPath: newLockPath())
        e.entry = .failed(51)
        let unreadable = await e.renewer.adopt(login, replacing: nil)
        XCTAssertEqual(unreadable, .notSaved)
        XCTAssertEqual(e.saved, [])

        let f = Instance(lockPath: newLockPath())
        f.saveWorks = false
        let failed = await f.renewer.adopt(login, replacing: nil)
        XCTAssertEqual(failed, .notSaved)
    }

    // MARK: - A save that reported failure but landed

    /// A's save of U reported failure (a read-back mismatch) but the write landed,
    /// so the entry holds U. A then renews U → U2 and that save really fails: U is
    /// spent and in the entry, so it must be marked.
    func testAnUnsavedSignInThatLandedIsMarkedWhenRenewed() async throws {
        let path = newLockPath()
        let u = signIn("u")
        let a = Instance(lockPath: path)
        a.renewer.unsaved = u
        a.entry = .found(u)
        a.saveWorks = false
        a.replies = [tokens("AAA-u2", "RRR-u2")]
        _ = await a.renewer.renew(u)
        XCTAssertEqual(a.sent, ["RRR-u"])
        XCTAssertEqual(try marker(at: path), Adoption.fingerprint(refreshToken: "RRR-u"))

        let b = Instance(lockPath: path)
        b.entry = .found(u)
        let outcome = await b.renewer.renew(u)
        XCTAssertEqual(outcome, .notSent)
        XCTAssertEqual(b.sent, [])
    }

    /// The same landed save, the other way round: B renews U from the entry (marking
    /// U, saving U2). A's retry must not put spent U back over U2.
    func testASpentUnsavedSignInIsDroppedNotSavedOverTheLiveOne() async throws {
        let path = newLockPath()
        let u = signIn("u")
        let b = Instance(lockPath: path)
        b.entry = .found(u)
        b.replies = [tokens("AAA-u2", "RRR-u2")]
        guard case .renewed(let u2) = await b.renewer.renew(u) else { return XCTFail() }

        let a = Instance(lockPath: path)
        a.renewer.unsaved = u
        a.entry = b.entry   // the one Keychain both instances share
        let pending = await a.renewer.retryUnsaved()
        XCTAssertNil(pending, "nothing pending: read the entry, which holds U2")
        XCTAssertNil(a.renewer.unsaved)
        XCTAssertEqual(a.saved, [])
        XCTAssertEqual(a.entry, .found(u2))
    }

    /// The normal path: the entry holds R1 (marked), U is pending and was never in
    /// the entry. The retry saves U; neither landed-save check fires.
    func testTheNormalRetryStillSavesTheUnsavedSignIn() async throws {
        let path = newLockPath()
        let r1 = signIn("r1")
        let a = await renewedButUnsaved(r1, at: path, into: "u")
        let u = try XCTUnwrap(a.renewer.unsaved)
        a.saveWorks = true
        let pending = await a.renewer.retryUnsaved()
        XCTAssertEqual(pending, u)
        XCTAssertNil(a.renewer.unsaved)
        XCTAssertEqual(a.entry, .found(u))
        XCTAssertEqual(try marker(at: path), Adoption.fingerprint(refreshToken: "RRR-r1"), "marker untouched")
    }

    // MARK: - The last save before quitting

    func testQuittingWithAnUnsavedSignInSavesItOnceWithoutARequest() async throws {
        let path = newLockPath()
        let a = await renewedButUnsaved(signIn("r1"), at: path, into: "u")
        let u = try XCTUnwrap(a.renewer.unsaved)
        a.maySend = false   // quitting
        a.saveWorks = true
        let savesBefore = a.saved.count
        await a.renewer.saveUnsavedBeforeQuit(waitingUpTo: 1)
        XCTAssertEqual(Array(a.saved.dropFirst(savesBefore)), [u])
        XCTAssertEqual(a.entry, .found(u))
        XCTAssertNil(a.renewer.unsaved)
        XCTAssertEqual(a.sent, ["RRR-r1"], "no request while quitting")
    }

    func testTheQuitSaveWaitsOnlyBrieflyForTheLock() async throws {
        let path = newLockPath()
        let other = try XCTUnwrap(FileLock(path: path))
        XCTAssertTrue(other.tryLock())
        let a = Instance(lockPath: path)
        a.renewer.unsaved = signIn("u")
        a.maySend = false
        let start = ProcessInfo.processInfo.systemUptime
        await a.renewer.saveUnsavedBeforeQuit(waitingUpTo: 0.3)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "waits for the lock even though quitting")
        XCTAssertLessThan(elapsed, 2)
        XCTAssertEqual(a.saved, [])
    }

    func testTheQuitSaveNeverSavesASpentSignIn() async throws {
        let path = newLockPath()
        let u = signIn("u")
        let b = Instance(lockPath: path)
        b.entry = .found(u)
        b.replies = [tokens("AAA-u2", "RRR-u2")]
        _ = await b.renewer.renew(u)   // marks U

        let a = Instance(lockPath: path)
        a.renewer.unsaved = u
        a.maySend = false
        await a.renewer.saveUnsavedBeforeQuit(waitingUpTo: 1)
        XCTAssertEqual(a.saved, [])
        XCTAssertNil(a.renewer.unsaved)
    }

    func testTheQuitSaveDoesNothingWithoutAnUnsavedSignIn() async {
        let a = Instance(lockPath: newLockPath())
        a.maySend = false
        await a.renewer.saveUnsavedBeforeQuit(waitingUpTo: 1)
        XCTAssertEqual(a.saved, [])
        XCTAssertEqual(a.sent, [])
    }
}
