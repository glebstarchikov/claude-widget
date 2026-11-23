import Foundation

/// Why a request went straight back to Claude Code's own prompt.
public enum ApprovalPassReason: String, Equatable, Sendable {
    case unknownVersion = "unknown protocol version"
    case settingOff = "setting off"
    case notAPermission = "not a permission"
    case noOwner = "no owner app"
    case ownerActive = "owner app active"
    case alreadyHeld = "already held"
    case noPill = "no pill"
}

/// What happens to a request the moment it arrives.
public enum ApprovalArrival: Equatable, Sendable {
    /// Ack it and hold it for an answer from the notch.
    case hold
    /// Hand it straight back to Claude Code's own prompt.
    case pass(ApprovalPassReason)
}

/// What an Allow or Deny click does.
public enum ApprovalAnswerVerdict: Equatable, Sendable {
    /// Send the answer to the hook.
    case send
    /// Allow for a request no row offers Allow for: refused.
    case allowNotOffered
    /// Allow within `ApprovalRules.allowSettle` of the requests changing under the pointer: ignored.
    case allowSettling
}

/// The approval coordinator's decisions (spec §8, §15, R17, R19 and the 0.5 s
/// settle), apart from AppKit so each can be tested. Nothing here approves
/// anything: the most it does is let an Allow click through (`answer`).
public enum ApprovalRules {
    /// Allow is ignored this soon after the pending requests changed, a request's
    /// row moved, the hub opened or the approval pill appeared: a click aimed at one
    /// thing (or a double-click) must not land on an Allow that slid into its place.
    public static let allowSettle: TimeInterval = 0.5

    /// Hold the request, or pass it back at once when the widget mustn't hold it:
    /// an unknown protocol version, the setting off, a tool that isn't a permission,
    /// an owner app it can't watch (R17), Gleb already in that app (mandatory, §15),
    /// a request already held, or nothing to show it on (R19).
    public static func arrival(of request: ApprovalRequest, answerFromNotch: Bool, frontmostBundleId: String?,
                               alreadyHeld: Bool, pillsShown: Bool, hubOpen: Bool) -> ApprovalArrival {
        guard request.v == 1 else { return .pass(.unknownVersion) }
        guard answerFromNotch else { return .pass(.settingOff) }
        guard !ApprovalPolicy.hookSkips(toolName: request.toolName) else { return .pass(.notAPermission) }
        guard let owner = request.ownerBundleId, !owner.isEmpty else { return .pass(.noOwner) }
        guard !ownerIsActive(owner: owner, active: frontmostBundleId) else { return .pass(.ownerActive) }
        guard !alreadyHeld else { return .pass(.alreadyHeld) }
        guard heldRequestsVisible(pillsShown: pillsShown, hubOpen: hubOpen) else { return .pass(.noPill) }
        return .hold
    }

    /// Whether the app `active` (frontmost, or just activated) is the request's
    /// owner, so Claude's own prompt is in front of Gleb and the notch steps aside:
    /// on arrival, and the moment the owner comes to the front while held (§15).
    /// Case-insensitive, so a mismatch in case can only make it pass, never hold.
    public static func ownerIsActive(owner: String?, active: String?) -> Bool {
        guard let owner, !owner.isEmpty, let active, !active.isEmpty else { return false }
        return owner.caseInsensitiveCompare(active) == .orderedSame
    }

    /// Held requests must be on screen: in the pill (Show alerts proactively) or
    /// the open hub. When neither will show them they pass (R19): on arrival, when
    /// the hub closes, and when proactive alerts are turned off.
    public static func heldRequestsVisible(pillsShown: Bool, hubOpen: Bool) -> Bool {
        pillsShown || hubOpen
    }

    /// The gate on every Allow/Deny click. Deny is fail-safe and always goes
    /// through. Allow goes through only for a request whose row offers Allow
    /// (`ApprovalPolicy.action`) and only once the requests have settled.
    public static func answer(allow: Bool, presentation: ApprovalPresentation, settled: Bool) -> ApprovalAnswerVerdict {
        guard allow else { return .send }
        guard ApprovalPolicy.action(for: presentation, on: .row) == .allow else { return .allowNotOffered }
        guard settled else { return .allowSettling }
        return .send
    }
}

/// When Allow last became unsafe to click, on a monotonic clock (seconds). Starts
/// settled; any change restarts the `ApprovalRules.allowSettle` wait.
public struct AllowSettle: Sendable {
    private var changedAt: TimeInterval = -.infinity
    /// Each request's row top edge (global points) as last reported while the hub
    /// is open. Kept by request id, so a row re-created elsewhere still counts as moved.
    private var rowTops: [String: Double] = [:]

    public init() {}

    /// Something changed under the pointer: the pending requests, the hub opening,
    /// the approval pill appearing.
    public mutating func restart(at now: TimeInterval) {
        changedAt = now
    }

    /// Whether Allow may be honored at `now`. A clock reading before the last change
    /// (or NaN) is not settled.
    public func isSettled(at now: TimeInterval) -> Bool {
        now - changedAt >= ApprovalRules.allowSettle
    }

    /// A request's row reported its top edge. If it moved (not merely appeared),
    /// an Allow under the pointer may now belong to it by accident: restart.
    public mutating func rowReported(id: String, top: Double, at now: TimeInterval) {
        let previous = rowTops[id]
        if ApprovalLayout.rowMoved(from: previous, to: top) {
            changedAt = now
            rowTops[id] = top
        } else if previous == nil {
            rowTops[id] = top
        }
    }

    /// The request ended: its row is gone.
    public mutating func forgetRow(_ id: String) {
        rowTops[id] = nil
    }

    /// The hub closed: rows appearing when it reopens aren't moves.
    public mutating func forgetRows() {
        rowTops.removeAll()
    }
}
