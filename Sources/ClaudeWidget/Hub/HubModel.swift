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

/// What the hub shows. Expanded wins over the pill; with neither, the hub is hidden.
@MainActor
final class HubModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var expanded = false
    @Published var pill: Pill?
    @Published var limits: LimitsState = .loading
    /// `limits` shows numbers loaded from the cache, not yet refreshed this run.
    @Published var limitsFromCache = false
    /// A renewed sign-in couldn't be saved to the Keychain (kept in memory, save retried).
    @Published var limitsSaveFailed = false
    /// Opens the Settings window (the Limits module's gear).
    var openSettings: () -> Void = {}
}
