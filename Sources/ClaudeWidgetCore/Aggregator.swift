import Foundation

public enum PeekEvent: Equatable, Sendable {
    case needsYou(Session)
    case finished(Session, duration: TimeInterval)
}

public enum Aggregator {
    public static func aggregate(_ sessions: [Session]) -> AggregateState {
        if sessions.isEmpty { return .asleep }
        if sessions.contains(where: { $0.state == .needsYou }) { return .needsYou }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        if sessions.contains(where: { $0.state == .waiting }) { return .waiting }
        return .ready
    }

    public static func peekEvents(old: [Session], new: [Session], now: Double) -> [PeekEvent] {
        let oldById = Dictionary(old.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [PeekEvent] = []
        for session in new {
            let previous = oldById[session.sessionId]
            if session.state == .needsYou && previous?.state != .needsYou {
                events.append(.needsYou(session))
            }
            if session.state == .waiting, let prev = previous, prev.state == .working,
               let since = prev.workingSince, now - since >= WidgetConstants.finishedPeekThreshold {
                events.append(.finished(session, duration: now - since))
            }
        }
        return events
    }
}
