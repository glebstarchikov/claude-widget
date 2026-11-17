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

/// What the hub shows. Expanded wins over the pill; with neither, the hub is hidden.
@MainActor
final class HubModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var expanded = false
    @Published var pill: Pill?
}
