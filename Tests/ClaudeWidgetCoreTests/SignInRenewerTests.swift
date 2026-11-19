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
                if self.saveWorks { self.entry = .found(credential) }
                return self.saveWorks
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
        XCTAssertEqual(again, .inconclusive, "a renewal that worked never reads as refused")
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
        XCTAssertEqual(outcome.failure, .unavailable, "never Sign-in expired")
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
}
