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
}

/// How one renewal attempt ended.
public enum RenewalOutcome: Equatable, Sendable {
    /// A sign-in to use: issued by the server, or already saved by another instance.
    case renewed(OAuthCredential)
    /// The server refused the refresh token (400, 401 or 403).
    case rejected
    /// No verdict on the sign-in: the request may have reached the server, but
    /// the answer says nothing about the token (timeout, 429, 5xx, another status,
    /// a 200 with no tokens in it, a token already due for renewal).
    case inconclusive
    /// Nothing left the Mac (no network, no host, the renewal lock or the
    /// widget's entry out of reach). Doesn't count against the renewal spacing.
    case notSent

    /// What the Limits module says when this attempt brought no usable sign-in and
    /// no newer Claude Code sign-in could be adopted. Only a refusal is "expired".
    public var failure: LimitsFailure { self == .rejected ? .expired : .unavailable }
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

    /// Classifies the token endpoint's answer. Only 400/401/403 is a refusal; a 200
    /// keeps whatever tokens it carries, because the server has already rotated the
    /// refresh token that was sent and the new one exists nowhere else.
    public static func outcome(status: Int, body: Data, now: Date) -> RenewalOutcome {
        guard status == 200 else { return refusedStatuses.contains(status) ? .rejected : .inconclusive }
        if let credential = try? parseResponse(body, now: now) { return .renewed(credential) }
        if let credential = salvage(body, now: now) { return .renewed(credential) }
        return .inconclusive
    }

    /// A renewal request that threw: `.notSent` only when it provably never left the Mac.
    public static func outcome(error: Error) -> RenewalOutcome {
        neverSent(error) ? .notSent : .inconclusive
    }

    /// Whether a 200's body wasn't the documented shape and `outcome` fell back to
    /// `salvage` (for logging; tokens never are).
    public static func wasSalvaged(_ body: Data, now: Date) -> Bool {
        (try? parseResponse(body, now: now)) == nil && salvage(body, now: now) != nil
    }

    /// The access and refresh tokens of a 200 whose `expires_in` is missing or
    /// unusable, expiring after `salvagedLifetime`. nil without both tokens.
    static func salvage(_ data: Data, now: Date) -> OAuthCredential? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty,
              let refresh = root["refresh_token"] as? String, !refresh.isEmpty
        else { return nil }
        return OAuthCredential(accessToken: access, refreshToken: refresh,
                               expiresAt: now.addingTimeInterval(salvagedLifetime))
    }

    /// A renewed sign-in already within 5 min of expiry is saved (its refresh token
    /// is the live one) but not used as fresh: renewing it again at once would loop.
    public static func usable(_ renewed: OAuthCredential, now: Date) -> RenewalOutcome {
        CredentialParser.needsRenewal(renewed, now: now) ? .inconclusive : .renewed(renewed)
    }
}

/// One renewal per 10 minutes, across polls. Inside the window the last attempt's
/// verdict stands, except that a renewal that worked reads as no verdict: being
/// asked again so soon (the feed refused the new token, or a stale copy expired)
/// says nothing against the sign-in.
public struct RenewalSpacing: Sendable {
    public static let interval: TimeInterval = 600

    /// When the last attempt that may have reached the server started, and whether
    /// the server refused it. Never a token.
    private var last: (at: Date, refused: Bool)?

    public init() {}

    /// nil: a renewal may be sent now. Otherwise the outcome that stands for one
    /// asked for at `now`. A clock set back before the last attempt ends the window.
    public func standing(at now: Date) -> RenewalOutcome? {
        guard let last else { return nil }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed >= 0, elapsed < Self.interval else { return nil }
        return last.refused ? .rejected : .inconclusive
    }

    /// Records an attempt started at `startedAt`. One that never left the Mac gives the slot back.
    public mutating func record(_ outcome: RenewalOutcome, startedAt: Date) {
        guard outcome != .notSent else { return }
        last = (startedAt, outcome == .rejected)
    }
}

/// What to do once this instance holds the renewal lock. Another instance may
/// have renewed the same sign-in while this one waited, rotating the refresh token
/// it was about to send; sending a rotated-out token gets refused (and, where the
/// server detects reuse, can revoke the sign-in). So the entry is read again first.
public enum RenewalPlan: Equatable, Sendable {
    /// The entry holds a newer sign-in that's still fresh: use it, send nothing.
    case use(OAuthCredential)
    /// Renew with this sign-in's refresh token.
    case renew(OAuthCredential)
    /// The entry couldn't be read, so another instance's renewal can't be ruled out: send nothing.
    case skip

    /// - Parameters:
    ///   - holding: the sign-in this poll was going to renew.
    ///   - holdingUnsaved: `holding` is a renewal whose save failed, so the entry
    ///     is older than it by construction and only `holding` is live.
    ///   - entry: the widget's entry, read after taking the lock.
    public static func afterLock(holding: OAuthCredential, holdingUnsaved: Bool,
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
