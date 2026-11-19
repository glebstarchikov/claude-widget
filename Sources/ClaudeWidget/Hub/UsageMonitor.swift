import Foundation
import os
import ClaudeWidgetCore

/// Keeps `HubModel.limits` current from Anthropic's usage feed (spec §7), using
/// the widget's own copy of a Claude sign-in (WidgetKeychain).
///
/// Each poll takes the sign-in (the widget's entry, else Claude Code's,
/// adopted), renews it if it's within 5 min of expiry, then reads the feed; a
/// 401/403 renews once and retries once. Renewal itself (one in flight, one per
/// 10 minutes, under the cross-instance lock, saved before use) is SignInRenewer.
@MainActor
final class UsageMonitor {
    private static let staleAfter: TimeInterval = 60
    private static let adoptedHashKey = "limitsAdoptedRefreshHash"

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
    /// Set once quitting starts: no renewal may be sent after that (prepareToQuit).
    private var quitting = false
    private var loop: Task<Void, Never>?
    private var lastAttempt: Date?
    private var lastGood: ProviderUsage?
    private var consecutiveFailures = 0

    private lazy var renewer = SignInRenewer(
        lockPath: WidgetConstants.renewalLock.path,
        maySend: { [weak self] in self.map { $0.running && !$0.quitting } ?? false },
        readOwn: { await WidgetKeychain.readOwn() },
        send: { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            return try await self.send(request)
        },
        save: { await WidgetKeychain.save($0) })

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
        model.limitsSaveFailed = renewer.unsaved != nil
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
    var renewing: Bool { renewer.renewing }

    /// Returns once the renewal in flight, if any, has finished: request and verified save.
    func renewalFinished() async {
        await renewer.finished()
    }

    /// Quitting has started: from now on no renewal is sent, and one still waiting
    /// for another instance's lock gives up (nothing has been sent, so nothing is lost).
    func prepareToQuit() {
        quitting = true
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
        if let pending = renewer.unsaved {
            if await WidgetKeychain.save(pending) { renewer.unsaved = nil }
            if active { model.limitsSaveFailed = renewer.unsaved != nil }
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
            renewer.unsaved = nil   // superseded by the new sign-in
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

    private func renew(_ credential: OAuthCredential) async -> RenewalOutcome {
        guard active else { return .notSent }
        let outcome = await renewer.renew(credential)
        if running { model.limitsSaveFailed = renewer.unsaved != nil }
        return outcome
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
