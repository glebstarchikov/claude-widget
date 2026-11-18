import Foundation
import os
import ClaudeWidgetCore

/// Keeps `HubModel.limits` current from Anthropic's usage feed (spec §7), using
/// the widget's own copy of a Claude sign-in (WidgetKeychain).
///
/// Each poll takes the sign-in (the widget's entry, else Claude Code's,
/// adopted), renews it if it's within 5 min of expiry, then reads the feed; a
/// 401/403 renews once and retries once. Renewal is guarded: one in flight, one
/// per 10 minutes (RenewalSpacing), and its result is saved (verified) before it's
/// used. Across app instances it runs under a file lock, with the widget's entry
/// read again once the lock is held (RenewalPlan).
@MainActor
final class UsageMonitor {
    private static let staleAfter: TimeInterval = 60
    private static let adoptedHashKey = "limitsAdoptedRefreshHash"
    /// How long a renewal waits for another instance's: longer than one renewal
    /// can take (60 s request limit, plus the Keychain read and verified save).
    private static let lockWait: TimeInterval = 90

    private enum UsageReply { case ok(ProviderUsage), unauthorized, failed }

    private let model: HubModel
    /// One session for usage and renewal. No URL cache or cookie store, so a
    /// request carrying a token never lands on disk; no redirects, so a token
    /// only goes to the host its request names. Bounded, so one stalled request
    /// (a renewal especially) can't hold up every later poll.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private var running = false
    private var loop: Task<Void, Never>?
    private var lastAttempt: Date?
    private var lastGood: ProviderUsage?
    private var consecutiveFailures = 0

    private var renewal: Task<RenewalOutcome, Never>?
    private var spacing = RenewalSpacing()
    /// A renewed sign-in whose save failed. The refresh token it replaced is
    /// already dead, so it's kept for this run and the save retried each poll.
    private var unsaved: OAuthCredential?

    init(model: HubModel) { self.model = model }

    /// Shows the cached numbers, then polls now and on UsagePollPolicy's schedule.
    func start() {
        guard !running else { return }
        running = true
        consecutiveFailures = 0
        if let cached = Self.loadCache() {
            lastGood = cached
            model.limits = .ok(cached)
            model.limitsFromCache = true
        } else {
            model.limits = .loading
        }
        model.limitsSaveFailed = unsaved != nil
        restartLoop()
    }

    /// Limits off: no further Keychain reads or network calls. A renewal already
    /// in flight still finishes and saves its result, because the server may
    /// already have rotated the refresh token it was sent.
    func stop() {
        running = false
        loop?.cancel(); loop = nil
        model.limits = .off
        model.limitsFromCache = false
        model.limitsSaveFailed = false
    }

    /// A renewal is in flight. Once it's sent, only its reply holds a live refresh
    /// token, so quitting before it's saved would lose the sign-in (AppDelegate waits).
    var renewing: Bool { renewal != nil }

    /// Returns once the renewal in flight, if any, has finished: request and verified save.
    func renewalFinished() async {
        _ = await renewal?.value
    }

    /// On hub open: poll now unless a poll started in the last 60 s. While polls
    /// succeed that's "the last success is over 60 s old"; while they fail it
    /// keeps hub opens from defeating the backoff.
    func refreshIfStale() {
        guard running else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) <= Self.staleAfter { return }
        restartLoop()
    }

    // MARK: - Polling

    /// Polls now, then again after whatever UsagePollPolicy says, until stopped.
    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.running else { return }
                let delay = await self.poll()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Limits are on and this poll hasn't been superseded.
    private var active: Bool { running && !Task.isCancelled }

    private func poll() async -> TimeInterval {
        lastAttempt = Date()
        let outcome = await fetch()
        consecutiveFailures = outcome == .failure ? consecutiveFailures + 1 : 0
        return UsagePollPolicy.nextDelay(after: outcome, consecutiveFailures: consecutiveFailures)
    }

    private func fetch() async -> UsageFetchOutcome {
        var credential: OAuthCredential
        switch await signIn() {
        case .success(let c): credential = c
        case .failure(let end): return finish(end)
        }
        if CredentialParser.needsRenewal(credential, now: Date()) {
            switch await renewOrReadopt(credential) {
            case .success(let c): credential = c
            case .failure(let end): return finish(end)
            }
        }
        var reply = await readUsage(with: credential)
        if case .unauthorized = reply {
            switch await renewOrReadopt(credential) {
            case .success(let renewed): reply = await readUsage(with: renewed)
            case .failure(let end): return finish(end)
            }
        }
        switch reply {
        case .ok(let usage): return show(usage)
        case .unauthorized: return finish(.expired)
        case .failed: return finish(.unavailable)
        }
    }

    private func show(_ usage: ProviderUsage) -> UsageFetchOutcome {
        guard active else { return .success }
        lastGood = usage
        model.limits = .ok(usage)
        model.limitsFromCache = false
        Self.saveCache(usage)
        return .success
    }

    private func finish(_ end: LimitsFailure) -> UsageFetchOutcome {
        switch end {
        case .expired:
            if active {
                Logger.limits.notice("sign-in expired")
                model.limits = .expired(last: lastGood)
            }
            return .unauthorized
        case .unavailable:
            if active { model.limits = .unavailable(last: lastGood) }
            return .failure
        }
    }

    // MARK: - Sign-in

    /// The sign-in for this poll: one renewed earlier whose save failed (retrying
    /// the save), else the widget's own entry, else Claude Code's, adopted.
    private func signIn() async -> Result<OAuthCredential, LimitsFailure> {
        if let pending = unsaved {
            if await WidgetKeychain.save(pending) { unsaved = nil }
            if active { model.limitsSaveFailed = unsaved != nil }
            return .success(pending)
        }
        switch await WidgetKeychain.readOwn() {
        case .found(let own):
            return .success(own)
        case .failed(let status):
            // The entry may exist (e.g. a locked Keychain), so never adopt over it.
            Logger.limits.error("sign-in read failed (status \(status))")
            return .failure(.unavailable)
        case .absent:
            guard active else { return .failure(.unavailable) }
            guard let adopted = await adoptClaudeCode(onlyIfNew: false) else { return .failure(.expired) }
            return .success(adopted)
        }
    }

    /// Copies Claude Code's sign-in into the widget's own entry and remembers a
    /// hash of its refresh token (never the token). With `onlyIfNew`, only a
    /// sign-in other than the one adopted last time (Gleb ran /login again).
    private func adoptClaudeCode(onlyIfNew: Bool) async -> OAuthCredential? {
        guard let theirs = await WidgetKeychain.readClaudeCode() else { return nil }
        let hash = Adoption.fingerprint(refreshToken: theirs.refreshToken)
        guard Adoption.shouldAdopt(fingerprint: hash, lastAdopted: UserDefaults.standard.string(forKey: Self.adoptedHashKey),
                                   onlyIfNew: onlyIfNew) else { return nil }
        guard active else { return nil }
        if await WidgetKeychain.save(theirs) {
            UserDefaults.standard.set(hash, forKey: Self.adoptedHashKey)
            unsaved = nil   // superseded by the new sign-in
            model.limitsSaveFailed = false
            Logger.limits.notice("adopted Claude Code's sign-in")
        } else {
            // It's still valid in Claude Code's entry: use it this poll, adopt again next poll.
            Logger.limits.error("adoption not saved; using Claude Code's sign-in for this poll")
        }
        return theirs
    }

    /// Renews `credential`, or failing that adopts a newer Claude Code sign-in.
    /// Only a renewal the server refused means the sign-in expired; any other
    /// failure leaves the limits unavailable (retried with backoff).
    private func renewOrReadopt(_ credential: OAuthCredential) async -> Result<OAuthCredential, LimitsFailure> {
        let result = await renew(credential)
        if case .renewed(let renewed) = result { return .success(renewed) }
        guard active else { return .failure(.unavailable) }
        if let adopted = await adoptClaudeCode(onlyIfNew: true) { return .success(adopted) }
        return .failure(result.failure)
    }

    /// At most one renewal in flight and one per 10 minutes; inside that window
    /// the last attempt's verdict stands (RenewalSpacing).
    private func renew(_ credential: OAuthCredential) async -> RenewalOutcome {
        if let renewal { return await renewal.value }
        if let standing = spacing.standing(at: Date()) {
            Logger.limits.notice("renewal skipped: one per 10 min")
            return standing
        }
        guard active else { return .notSent }
        // Unstructured, so stopping the poll can't cancel it: once the request is
        // sent, only the reply holds a live refresh token.
        let task = Task { await self.lockedRenewal(credential) }
        renewal = task
        let result = await task.value
        renewal = nil
        return result
    }

    /// Read own entry → renew → save, all under the cross-instance lock, so another
    /// copy of the app can't send the same refresh token in between.
    private func lockedRenewal(_ credential: OAuthCredential) async -> RenewalOutcome {
        guard let lock = FileLock(path: WidgetConstants.renewalLock.path) else {
            Logger.limits.error("renewal lock unavailable")
            return .notSent
        }
        guard await lock.lock(waitingUpTo: Self.lockWait) else {
            Logger.limits.error("renewal lock still held by another instance")
            return .notSent
        }
        defer { lock.unlock() }
        // Limits turned off while waiting: nothing has been sent, so send nothing.
        guard running else { return .notSent }
        let entry = await WidgetKeychain.readOwn()
        switch RenewalPlan.afterLock(holding: credential, holdingUnsaved: credential == unsaved,
                                     entry: entry, now: Date()) {
        case .use(let stored):
            Logger.limits.notice("renewal skipped: another instance already renewed")
            return .renewed(stored)
        case .skip:
            Logger.limits.error("renewal skipped: own entry unreadable")
            return .notSent
        case .renew(let current):
            let started = Date()
            let outcome = await performRenewal(current)
            spacing.record(outcome, startedAt: started)
            return outcome
        }
    }

    private func performRenewal(_ credential: OAuthCredential) async -> RenewalOutcome {
        let reply: (body: Data, status: Int)
        do {
            reply = try await send(TokenRefresh.makeRequest(refreshToken: credential.refreshToken))
        } catch {
            Logger.limits.error("renewal request failed (\(Self.errorCode(error)))")
            return TokenRefresh.outcome(error: error)
        }
        Logger.limits.notice("renewal status \(reply.status)")
        let now = Date()
        let outcome = TokenRefresh.outcome(status: reply.status, body: reply.body, now: now)
        guard case .renewed(let renewed) = outcome else { return outcome }
        if TokenRefresh.wasSalvaged(reply.body, now: now) {
            Logger.limits.error("renewal response unexpected; kept its tokens with a 1 h expiry")
        }
        // Save before use. The refresh token just sent is dead now, so a failed
        // save keeps the new sign-in in memory and retries each poll.
        unsaved = await WidgetKeychain.save(renewed) ? nil : renewed
        if running { model.limitsSaveFailed = unsaved != nil }
        // Already due for renewal again: no verdict, never a reason to renew again.
        let usable = TokenRefresh.usable(renewed, now: Date())
        if usable == .inconclusive { Logger.limits.error("renewed sign-in is already within 5 min of expiry") }
        return usable
    }

    // MARK: - Feed

    private func readUsage(with credential: OAuthCredential) async -> UsageReply {
        guard active else { return .failed }
        let reply: (body: Data, status: Int)
        do {
            reply = try await send(UsageRequest.make(token: credential.accessToken))
        } catch {
            Logger.limits.error("usage request failed (\(Self.errorCode(error)))")
            return .failed
        }
        Logger.limits.notice("usage status \(reply.status)")
        switch reply.status {
        case 200:
            guard let usage = try? UsageParser.parseClaude(reply.body, fetchedAt: Date()) else {
                Logger.limits.error("usage response unreadable")
                return .failed
            }
            return .ok(usage)
        case 401, 403:
            return .unauthorized
        default:
            return .failed
        }
    }

    private func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        let (body, response) = try await session.data(for: request)
        return (body, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func errorCode(_ error: Error) -> Int {
        (error as? URLError)?.code.rawValue ?? -1
    }

    // MARK: - Cache

    private static func loadCache() -> ProviderUsage? {
        guard let data = try? Data(contentsOf: WidgetConstants.limitsCache) else { return nil }
        return try? JSONDecoder().decode(ProviderUsage.self, from: data)
    }

    /// Numbers and a timestamp only, never a sign-in.
    private static func saveCache(_ usage: ProviderUsage) {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? FileManager.default.createDirectory(at: WidgetConstants.baseDir, withIntermediateDirectories: true)
        try? data.write(to: WidgetConstants.limitsCache, options: .atomic)
    }
}

/// Refuses redirects, so a request's Authorization header never follows one elsewhere.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
