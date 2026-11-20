import Foundation
import os

private let log = Logger(subsystem: "com.glebstarchikov.claude-widget", category: "limits")

/// Renews the widget's sign-in (spec §7). At most one renewal in flight and one
/// per 10 minutes (RenewalSpacing). Every write to the widget's entry (a
/// renewal's save, the retry of one that failed, an adoption of Claude Code's
/// sign-in) runs under the cross-instance renewal lock, so two of them never
/// race, in this process or another. A renewal reads the entry again under it
/// (RenewalPlan), never sends a refresh token already spent, and saves its result
/// (verified) before it's used. The Keychain, the network and whether sending is
/// still allowed come in as closures, so all of this is tested here, not in the app.
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
    /// so it's kept for this run: renewed in place of the entry, and saved again
    /// each poll (`retryUnsaved`).
    public internal(set) var unsaved: OAuthCredential?

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

    // MARK: - Renewal

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
        let task = Task {
            await self.withLock { lock in await self.renewUnderLock(credential, lock: lock) } ?? .notSent
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func renewUnderLock(_ credential: OAuthCredential, lock: FileLock) async -> RenewalOutcome {
        let holdingUnsaved = credential == unsaved
        let entry = await readOwn()
        /// The token is in the entry, where another instance could read and send it.
        func entryHolds(_ c: OAuthCredential) -> Bool {
            if case .found(let stored) = entry { return stored.refreshToken == c.refreshToken }
            return false
        }
        switch RenewalPlan.afterLock(holding: credential, holdingUnsaved: holdingUnsaved,
                                     entry: entry, spent: marker(in: lock), now: Date()) {
        case .use(let stored):
            log.notice("renewal skipped: another instance already renewed")
            return .renewed(stored)
        case .skip:
            log.error("renewal skipped: own entry unreadable")
            return .notSent
        case .spent:
            log.error("renewal skipped: refresh token already spent, its renewal not yet saved")
            return .notSent
        case .lost:
            // Nothing sent, so the 10-minute spacing isn't used up either.
            log.error("renewal skipped: refresh token spent over 30 min ago and its renewal never saved")
            return .rejected
        case .renew(let current):
            // Again, as the app may have started quitting while the entry was read.
            guard maySend() else {
                log.notice("renewal not sent: quitting or limits off")
                return .notSent
            }
            let started = ContinuousClock.now
            // An unsaved renewal's token is usually not in the entry, so no other
            // instance can send it and the marker stays on the spent token the entry
            // does hold. But a save that reported failure may have landed (a read-back
            // mismatch after the write), so it's marked whenever the entry holds it.
            let outcome = await sendAndSave(current, lock: lock, markSpent: !holdingUnsaved || entryHolds(current))
            spacing.record(outcome, startedAt: started)
            return outcome
        }
    }

    private func sendAndSave(_ credential: OAuthCredential, lock: FileLock, markSpent: Bool) async -> RenewalOutcome {
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
        if markSpent, renewed.refreshToken != credential.refreshToken,
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

    // MARK: - Other writes to the entry

    /// Saves the unsaved renewal again, under the lock, so never alongside a
    /// renewal's own save (which may have replaced it meanwhile). Returns the
    /// sign-in to use this poll: the one pending now, saved or not. nil when none
    /// is pending any more: read the entry.
    public func retryUnsaved() async -> OAuthCredential? {
        guard unsaved != nil else { return nil }
        let retried = await withLock { await self.savePending(under: $0) }
        // Lock out of reach: use the pending sign-in, unsaved, this poll.
        return retried ?? unsaved
    }

    /// One last save of the unsaved renewal while quitting, when it's the only copy
    /// of the live sign-in: the Keychain only, never a request. Under the lock (it
    /// waits at most `wait`, quitting or not) with the same spent check as
    /// `retryUnsaved`.
    public func saveUnsavedBeforeQuit(waitingUpTo wait: TimeInterval) async {
        guard unsaved != nil else { return }
        _ = await withLock(waitingUpTo: wait, whileMaySend: false) { await self.savePending(under: $0) }
    }

    /// Under the lock: saves the pending renewal and returns it, nil if none is
    /// pending. Not if the marker names it as spent: a save of it that reported
    /// failure had in fact landed, and another instance has since renewed it from
    /// the entry. Saving it again would put a dead token over the live one.
    private func savePending(under lock: FileLock) async -> OAuthCredential? {
        guard let pending = unsaved else { return nil }
        if marker(in: lock)?.names(pending) == true {
            log.error("unsaved sign-in dropped: another instance already renewed it from the entry")
            unsaved = nil
            return nil
        }
        if await save(pending) { unsaved = nil }
        return pending
    }

    public enum AdoptionSave: Equatable, Sendable {
        /// Saved as the widget's own.
        case saved
        /// Not saved (save failed, entry unreadable, or the lock out of reach): use it this poll only.
        case notSaved
        /// The widget's sign-in changed since the caller looked (a renewal saved or
        /// kept a newer one): nothing written, use this one instead.
        case superseded(OAuthCredential)
        /// Its refresh token is one a renewal here already spent: never adopted.
        case spent
    }

    /// Saves Claude Code's sign-in as the widget's own, under the lock, but only in
    /// place of `replacing`: the widget's sign-in the caller saw and is giving up on
    /// (nil: it found none). Anything else there now is newer, so it wins.
    public func adopt(_ theirs: OAuthCredential, replacing: OAuthCredential?) async -> AdoptionSave {
        await withLock { lock in
            let current: OAuthCredential?
            if let unsaved = self.unsaved {
                current = unsaved
            } else {
                switch await self.readOwn() {
                case .found(let own): current = own
                case .absent: current = nil
                case .failed: return .notSaved
                }
            }
            if let current, current.refreshToken != replacing?.refreshToken { return .superseded(current) }
            if self.marker(in: lock)?.names(theirs) == true { return .spent }
            guard await self.save(theirs) else { return .notSaved }
            self.unsaved = nil   // it was `replacing`, now replaced
            return .saved
        } ?? .notSaved
    }

    // MARK: - Lock

    /// Runs `body` holding the renewal lock; nil if it couldn't be taken. Waits up
    /// to `wait` (default `lockWait`), giving up early once `maySend` turns false
    /// unless `whileMaySend` is false.
    private func withLock<T>(waitingUpTo wait: TimeInterval? = nil, whileMaySend: Bool = true,
                             _ body: (FileLock) async -> T) async -> T? {
        guard let lock = FileLock(path: lockPath) else {
            log.error("renewal lock unavailable")
            return nil
        }
        let took = await lock.lock(waitingUpTo: wait ?? lockWait, interval: lockInterval,
                                   giveUpIf: { @MainActor [weak self] in whileMaySend && !(self?.maySend() ?? false) })
        guard took else {
            if maySend() {
                log.error("renewal lock still held by another instance")
            } else {
                log.notice("renewal lock not taken: quitting or limits off")
            }
            return nil
        }
        defer { lock.unlock() }
        return await body(lock)
    }

    /// The lock file's spent-token marker, if any. An unknown age reads as fresh.
    private func marker(in lock: FileLock) -> SpentMarker? {
        let fingerprint = lock.contents()
        guard !fingerprint.isEmpty else { return nil }
        return SpentMarker(fingerprint: fingerprint, markedAt: lock.modified() ?? Date())
    }
}
