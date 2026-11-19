import Foundation
import CryptoKit

/// The widget's own Keychain entry, as read (spec §7).
public enum StoredSignIn: Equatable, Sendable {
    case found(OAuthCredential)
    /// No entry, or one that doesn't decode: safe to replace.
    case absent
    /// Any other failure (e.g. a locked Keychain): the entry may exist, so don't replace it.
    case failed(Int32)
}

/// What the Limits module says when a poll gets no numbers.
public enum LimitsFailure: Error, Equatable, Sendable {
    /// "Sign-in expired · run /login in terminal Claude": the server refused the sign-in.
    case expired
    /// "Limits unavailable": nothing says the sign-in is bad (no network, rate
    /// limited, a server error, an unexpected answer). Retried with backoff.
    case unavailable

    /// How the next poll is scheduled (UsagePollPolicy): an expired sign-in waits
    /// 30 minutes, anything else backs off from 60 s.
    public var fetchOutcome: UsageFetchOutcome { self == .expired ? .unauthorized : .failure }
}

/// How one renewal attempt ended.
public enum RenewalOutcome: Equatable, Sendable {
    /// A sign-in to use: issued by the server, or already saved by another instance.
    case renewed(OAuthCredential)
    /// The refresh token is dead: the server refused it (400, 401 or 403), or it
    /// was spent over `SpentMarker.lifetime` ago by a renewal that was never saved
    /// (nothing sent then).
    case rejected
    /// No verdict on the sign-in: the request may have reached the server, but
    /// the answer says nothing about the token (timeout, 429, 5xx, another status,
    /// a 200 with no tokens in it, a token already due for renewal).
    case inconclusive
    /// Nothing was sent, or it provably never left the Mac: no network or host,
    /// the renewal lock or the widget's entry out of reach, quitting or Limits off,
    /// or a refresh token already spent. Doesn't count against the renewal spacing.
    case notSent
    /// Not sent: this instance renewed the sign-in less than 10 minutes ago, and
    /// that renewal worked (RenewalSpacing).
    case recentlyRenewed

    /// What the Limits module says when this attempt brought no usable sign-in and
    /// no newer Claude Code sign-in could be adopted. A refusal is "expired". So is
    /// a renewal skipped as recent when it was asked for because the feed refused
    /// the sign-in (`afterFeedRefusal`): the feed refused one renewed minutes ago,
    /// which is what read as "expired" the first time, so the label stays put and
    /// polls keep the 30-minute wait instead of backing off from 60 s. Anything
    /// else is "unavailable".
    public func failure(afterFeedRefusal: Bool) -> LimitsFailure {
        switch self {
        case .rejected: return .expired
        case .recentlyRenewed: return afterFeedRefusal ? .expired : .unavailable
        case .renewed, .inconclusive, .notSent: return .unavailable
        }
    }
}

extension TokenRefresh {
    /// Lifetime given to an access token from a 200 whose `expires_in` is missing or
    /// unusable: an hour, well inside the measured 8 h, so the widget renews early
    /// instead of trusting a token past its real expiry.
    public static let salvagedLifetime: TimeInterval = 3600
    /// The longest `expires_in` taken at its word: the refresh token itself lasts about 30 days.
    public static let maxLifetime: TimeInterval = 30 * 86400
    /// Answers meaning the server refused the refresh token itself.
    static let refusedStatuses: Set<Int> = [400, 401, 403]

    /// Classifies the token endpoint's answer to a renewal of `sent`. Only
    /// 400/401/403 is a refusal; a 200 keeps whatever tokens it carries, because
    /// the server may already have rotated the refresh token that was sent and the
    /// new one exists nowhere else.
    public static func outcome(status: Int, body: Data, sent: OAuthCredential, now: Date) -> RenewalOutcome {
        guard status == 200 else { return refusedStatuses.contains(status) ? .rejected : .inconclusive }
        if let credential = try? parseResponse(body, now: now) { return .renewed(credential) }
        if let credential = salvage(body, sent: sent, now: now) { return .renewed(credential) }
        return .inconclusive
    }

    /// A renewal request that threw: `.notSent` only when it provably never left the Mac.
    public static func outcome(error: Error) -> RenewalOutcome {
        neverSent(error) ? .notSent : .inconclusive
    }

    /// Whether a 200's body wasn't the documented shape and `outcome` fell back to
    /// `salvage` (for logging; tokens never are).
    public static func wasSalvaged(_ body: Data, sent: OAuthCredential, now: Date) -> Bool {
        (try? parseResponse(body, now: now)) == nil && salvage(body, sent: sent, now: now) != nil
    }

    /// The tokens of a 200 that isn't the documented shape, so none is dropped:
    /// - both: kept, expiring after `salvagedLifetime`;
    /// - only an access token: the server didn't rotate, so the refresh token
    ///   `sent` is still the live one; kept beside the new access token;
    /// - only a refresh token: it's the live one now, saved beside an access token
    ///   already marked expired, so it's renewed again (no verdict this poll).
    /// nil with neither.
    static func salvage(_ data: Data, sent: OAuthCredential, now: Date) -> OAuthCredential? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let access = (root["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let refresh = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch (access, refresh) {
        case let (access?, refresh?):
            return OAuthCredential(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(salvagedLifetime))
        case let (access?, nil):
            return OAuthCredential(accessToken: access, refreshToken: sent.refreshToken,
                                   expiresAt: now.addingTimeInterval(salvagedLifetime))
        case let (nil, refresh?):
            return OAuthCredential(accessToken: sent.accessToken, refreshToken: refresh, expiresAt: .distantPast)
        case (nil, nil):
            return nil
        }
    }

    /// A renewed sign-in already within 5 min of expiry is saved (its refresh token
    /// is the live one) but not used as fresh: renewing it again at once would loop.
    public static func usable(_ renewed: OAuthCredential, now: Date) -> RenewalOutcome {
        CredentialParser.needsRenewal(renewed, now: now) ? .inconclusive : .renewed(renewed)
    }
}

/// One renewal per 10 minutes, across polls. Inside the window the last attempt's
/// verdict stands: a refusal, no verdict, or "recently renewed" for a renewal
/// that worked (never a refusal: what it means depends on why a renewal was
/// asked for again, see `RenewalOutcome.failure`). Measured on a monotonic clock that keeps
/// counting through sleep, so setting the Mac's clock either way can't shorten
/// or stretch the window.
public struct RenewalSpacing: Sendable {
    public static let interval: Duration = .seconds(600)

    private enum Verdict: Sendable { case refused, renewed, none }

    /// When the last attempt that may have reached the server started, and how it
    /// ended. Never a token.
    private var last: (at: ContinuousClock.Instant, verdict: Verdict)?

    public init() {}

    /// nil: a renewal may be sent now. Otherwise the outcome that stands for one asked for at `now`.
    public func standing(at now: ContinuousClock.Instant) -> RenewalOutcome? {
        guard let last, now - last.at < Self.interval else { return nil }
        switch last.verdict {
        case .refused: return .rejected
        case .renewed: return .recentlyRenewed
        case .none: return .inconclusive
        }
    }

    /// Records an attempt started at `startedAt`. One that never left the Mac gives the slot back.
    public mutating func record(_ outcome: RenewalOutcome, startedAt: ContinuousClock.Instant) {
        switch outcome {
        case .notSent, .recentlyRenewed: return
        case .rejected: last = (startedAt, .refused)
        case .renewed: last = (startedAt, .renewed)
        case .inconclusive: last = (startedAt, .none)
        }
    }
}

/// What to do once this instance holds the renewal lock. Another instance may
/// have renewed the same sign-in while this one waited, rotating the refresh token
/// it was about to send; sending a rotated-out token gets refused (and, where the
/// server detects reuse, can revoke the sign-in). So the entry is read again first,
/// and the lock file's spent-token marker is checked.
public enum RenewalPlan: Equatable, Sendable {
    /// The entry holds a newer sign-in that's still fresh: use it, send nothing.
    case use(OAuthCredential)
    /// Renew with this sign-in's refresh token.
    case renew(OAuthCredential)
    /// The entry couldn't be read, so another instance's renewal can't be ruled out: send nothing.
    case skip
    /// The refresh token that would be sent was already spent: an instance renewed
    /// it but couldn't save the result, so the entry still holds it. Send nothing;
    /// no verdict (that instance keeps retrying its save).
    case spent
    /// As `spent`, but marked over `SpentMarker.lifetime` ago: the instance that
    /// held the renewal has most likely quit or crashed without saving it, so the
    /// sign-in reads as lost. Send nothing; it reads as expired (run /login).
    case lost

    /// - Parameters:
    ///   - holding: the sign-in this poll was going to renew.
    ///   - holdingUnsaved: `holding` is a renewal whose save failed, so the entry
    ///     is older than it by construction and only `holding` is live.
    ///   - entry: the widget's entry, read after taking the lock.
    ///   - spent: the lock file's spent-token marker; nil if none.
    public static func afterLock(holding: OAuthCredential, holdingUnsaved: Bool, entry: StoredSignIn,
                                 spent: SpentMarker?, now: Date) -> RenewalPlan {
        let plan = beforeMarker(holding: holding, holdingUnsaved: holdingUnsaved, entry: entry, now: now)
        guard case .renew(let c) = plan, let spent, spent.names(c) else { return plan }
        return now.timeIntervalSince(spent.markedAt) >= SpentMarker.lifetime ? .lost : .spent
    }

    private static func beforeMarker(holding: OAuthCredential, holdingUnsaved: Bool,
                                     entry: StoredSignIn, now: Date) -> RenewalPlan {
        if holdingUnsaved { return .renew(holding) }
        switch entry {
        case .failed: return .skip
        case .absent: return .renew(holding)
        case .found(let stored):
            guard stored.refreshToken != holding.refreshToken else { return .renew(holding) }
            return CredentialParser.needsRenewal(stored, now: now) ? .renew(stored) : .use(stored)
        }
    }
}

/// The lock file's record of the last refresh token a renewal spent (the server
/// rotated it): its fingerprint, never the token, and when it was written.
public struct SpentMarker: Equatable, Sendable {
    /// How long a marker only holds renewals back. Its age is the time since the
    /// token was spent (only a renewal writes the file; a retried save doesn't touch
    /// it), not a sign of whether the instance holding the new token is alive. That
    /// instance retries its save every poll, so by now it has most likely quit or
    /// crashed without saving, and the entry's sign-in reads as lost. If it's in fact
    /// still running with failing saves (or Limits off, or the Mac asleep), this
    /// reads "expired" early. Nothing is sent either way, and its next good save
    /// puts the live sign-in in the entry. Wall-clock time (the file's mtime): a
    /// clock change only moves when the label turns from "unavailable" to "expired".
    public static let lifetime: TimeInterval = 1800

    public var fingerprint: String
    public var markedAt: Date

    public init(fingerprint: String, markedAt: Date) {
        self.fingerprint = fingerprint
        self.markedAt = markedAt
    }

    /// Whether this marks `credential`'s refresh token as spent.
    public func names(_ credential: OAuthCredential) -> Bool {
        fingerprint == Adoption.fingerprint(refreshToken: credential.refreshToken)
    }
}

/// Copying Claude Code's sign-in into the widget's entry (spec §7).
public enum Adoption {
    /// A one-way fingerprint of a refresh token, remembered to recognize the sign-in
    /// adopted last. The token itself is never stored outside the Keychain.
    public static func fingerprint(refreshToken: String) -> String {
        SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Always adopt when the widget has no entry; after a failed renewal only a
    /// sign-in other than the one adopted last time (Gleb ran /login again).
    public static func shouldAdopt(fingerprint: String, lastAdopted: String?, onlyIfNew: Bool) -> Bool {
        !onlyIfNew || fingerprint != lastAdopted
    }
}
