import AppKit
import Foundation
import ClaudeWidgetCore

/// A small alert under the notch, shown instead of the whole hub.
enum Pill: Equatable {
    case needsYou(sessionId: String)
    case finished(sessionId: String, duration: TimeInterval)

    var sessionId: String {
        switch self {
        case .needsYou(let id), .finished(let id, _): return id
        }
    }
}

/// Claude's usage limits for the Limits module, kept current by UsageMonitor.
/// The failure states carry the last numbers shown, if any.
enum LimitsState: Equatable {
    case off
    case loading
    case ok(ProviderUsage)
    case expired(last: ProviderUsage?)
    case unavailable(last: ProviderUsage?)
}

/// A transport button on the now-playing card.
enum NowPlayingCommand { case togglePlayPause, previous, next }

/// A permission request the widget acked and is holding for Gleb's answer (spec §8).
struct PendingApproval: Identifiable, Equatable {
    let id: String
    let request: ApprovalRequest
    let presentation: ApprovalPresentation
    let receivedAt: Date
}

/// What the hub shows. Expanded wins over the pill; with neither, the hub is hidden.
@MainActor
final class HubModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var expanded = false
    @Published var pill: Pill?
    /// Live permission requests, oldest first. A needs-you pill shows the first.
    @Published var pending: [PendingApproval] = []
    /// The pending request the hub scrolls to when it opens from the pill's Review button.
    @Published var revealApprovalId: String?
    @Published var limits: LimitsState = .loading
    /// `limits` shows numbers loaded from the cache, not yet refreshed this run.
    @Published var limitsFromCache = false
    /// A renewed sign-in couldn't be saved to the Keychain (kept in memory, save retried).
    @Published var limitsSaveFailed = false
    /// What's playing, kept current by NowPlayingMonitor. nil: nothing is.
    @Published var nowPlaying: NowPlaying?
    @Published var nowPlayingArtwork: NSImage?
    /// When the current pause began (NowPlayingRules.pausedAt).
    @Published var nowPlayingPausedAt: Date?
    var nowPlayingCommand: (NowPlayingCommand) -> Void = { _ in }
    /// Brings the playing app forward (the card's title).
    var openNowPlayingApp: () -> Void = {}
    /// Opens the Settings window (the Limits module's gear).
    var openSettings: () -> Void = {}
    /// The Allow/Deny buttons (ApprovalCoordinator.answer).
    var answerApproval: (_ id: String, _ allow: Bool) -> Void = { _, _ in }
    /// The pill's Review button: opens the hub at the request (by id).
    var reviewApproval: (_ id: String) -> Void = { _ in }
    /// A request's row reports its top edge (ApprovalCoordinator.rowPositioned).
    var approvalRowTop: (_ id: String, _ top: Double) -> Void = { _, _ in }
    /// The approval pill appeared under the pointer (ApprovalCoordinator.settle).
    var approvalPillShown: () -> Void = {}
}
