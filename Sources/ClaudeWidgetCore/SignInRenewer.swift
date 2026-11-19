import Foundation
import os

private let log = Logger(subsystem: "com.glebstarchikov.claude-widget", category: "limits")

/// Renews the widget's sign-in (spec §7). At most one renewal in flight and one
/// per 10 minutes (RenewalSpacing). Each one runs under the cross-instance lock:
/// the widget's entry is read again (RenewalPlan), a refresh token already spent
/// is never sent, and the result is saved (verified) before it's used. The
/// Keychain, the network and whether sending is still allowed come in as
/// closures, so the whole sequence is tested here rather than in the app.
@MainActor
public final class SignInRenewer {
    private let lockPath: String
    private let lockWait: TimeInterval
    private let lockInterval: Duration
    private let maySend: @MainActor () -> Bool
    private let readOwn: @MainActor () async -> StoredSignIn
    private let send: @MainActor (URLRequest) async throws -> (body: Data, status: Int)
    private let save: @MainActor (OAuthCredential) async -> Bool

    private var spacing = RenewalSpacing()
    private var inFlight: Task<RenewalOutcome, Never>?

    /// A renewed sign-in whose save failed. The refresh token it replaced is spent,
    /// so it's kept for this run: renewed in place of the entry, and saved again by
    /// the caller each poll.
    public var unsaved: OAuthCredential?

    /// - Parameters:
    ///   - lockPath: the renewal lock (`WidgetConstants.renewalLock`). It also holds
    ///     the spent-token marker: a fingerprint, never a token.
    ///   - lockWait: how long to wait for another instance's renewal: longer than
    ///     one can take (60 s request limit, plus the Keychain read and verified save).
    ///   - maySend: Limits are on and the app isn't quitting. Checked while waiting
    ///     for the lock and again just before sending: once a request is sent, only
    ///     its reply holds a live refresh token, so the app must be able to wait for it.
    ///   - readOwn: the widget's own Keychain entry.
    ///   - send: sends a request to the token endpoint.
    ///   - save: writes the widget's own entry and verifies it; false if it didn't stick.
    public init(lockPath: String, lockWait: TimeInterval = 90, lockInterval: Duration = .milliseconds(100),
                maySend: @escaping @MainActor () -> Bool,
                readOwn: @escaping @MainActor () async -> StoredSignIn,
                send: @escaping @MainActor (URLRequest) async throws -> (body: Data, status: Int),
                save: @escaping @MainActor (OAuthCredential) async -> Bool) {
        self.lockPath = lockPath
        self.lockWait = lockWait
        self.lockInterval = lockInterval
        self.maySend = maySend
        self.readOwn = readOwn
        self.send = send
        self.save = save
    }

    /// A renewal is in flight (quitting waits for it).
    public var renewing: Bool { inFlight != nil }

    /// Returns once the renewal in flight, if any, has finished: request and verified save.
    public func finished() async {
        _ = await inFlight?.value
    }

    /// Renews `credential`, or joins the renewal already in flight. Inside the
    /// 10-minute window the last attempt's verdict stands.
    public func renew(_ credential: OAuthCredential) async -> RenewalOutcome {
        if let inFlight { return await inFlight.value }
        if let standing = spacing.standing(at: .now) {
            log.notice("renewal skipped: one per 10 min")
            return standing
        }
        // Unstructured, so stopping the poll can't cancel it: once the request is
        // sent, only the reply holds a live refresh token.
        let task = Task { await self.underLock(credential) }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func underLock(_ credential: OAuthCredential) async -> RenewalOutcome {
        guard let lock = FileLock(path: lockPath) else {
            log.error("renewal lock unavailable")
            return .notSent
        }
        let took = await lock.lock(waitingUpTo: lockWait, interval: lockInterval,
                                   giveUpIf: { @MainActor [weak self] in !(self?.maySend() ?? false) })
        guard took else {
            if maySend() {
                log.error("renewal lock still held by another instance")
            } else {
                log.notice("renewal not sent: quitting or limits off")
            }
            return .notSent
        }
        defer { lock.unlock() }
        let entry = await readOwn()
        switch RenewalPlan.afterLock(holding: credential, holdingUnsaved: credential == unsaved,
                                     entry: entry, spent: lock.contents(), now: Date()) {
        case .use(let stored):
            log.notice("renewal skipped: another instance already renewed")
            return .renewed(stored)
        case .skip:
            log.error("renewal skipped: own entry unreadable")
            return .notSent
        case .spent:
            log.error("renewal skipped: refresh token already spent, its renewal not yet saved")
            return .notSent
        case .renew(let current):
            // Again, as the app may have started quitting while the entry was read.
            guard maySend() else {
                log.notice("renewal not sent: quitting or limits off")
                return .notSent
            }
            let started = ContinuousClock.now
            let outcome = await sendAndSave(current, lock: lock)
            spacing.record(outcome, startedAt: started)
            return outcome
        }
    }

    private func sendAndSave(_ credential: OAuthCredential, lock: FileLock) async -> RenewalOutcome {
        let reply: (body: Data, status: Int)
        do {
            reply = try await send(TokenRefresh.makeRequest(refreshToken: credential.refreshToken))
        } catch {
            log.error("renewal request failed (\((error as? URLError)?.code.rawValue ?? -1))")
            return TokenRefresh.outcome(error: error)
        }
        log.notice("renewal status \(reply.status)")
        let now = Date()
        let outcome = TokenRefresh.outcome(status: reply.status, body: reply.body, sent: credential, now: now)
        guard case .renewed(let renewed) = outcome else { return outcome }
        if TokenRefresh.wasSalvaged(reply.body, sent: credential, now: now) {
            log.error("renewal response unexpected; kept the tokens it carried")
        }
        // The server rotated the refresh token just sent, so it's spent. Marked before
        // the save: if the save fails the entry still holds it, and another instance
        // must not send it. Never marked before sending, as a request that didn't
        // reach the server would then block renewal for good.
        if renewed.refreshToken != credential.refreshToken,
           !lock.replaceContents(with: Adoption.fingerprint(refreshToken: credential.refreshToken)) {
            log.error("spent-token marker not written")
        }
        // Save before use. A failed save keeps the new sign-in in memory.
        unsaved = await save(renewed) ? nil : renewed
        // Already due for renewal again: no verdict, never a reason to renew again.
        let usable = TokenRefresh.usable(renewed, now: Date())
        if usable == .inconclusive { log.error("renewed sign-in is already due for renewal") }
        return usable
    }
}
