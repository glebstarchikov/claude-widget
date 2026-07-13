import Foundation

public enum PushPriority: String, Equatable, Sendable {
    case min, low, `default`, high, urgent
}

public struct PushPayload: Equatable, Sendable {
    public let title: String
    public let body: String
    public let priority: PushPriority
    public let tags: [String]

    public init(title: String, body: String, priority: PushPriority, tags: [String]) {
        self.title = title
        self.body = body
        self.priority = priority
        self.tags = tags
    }
}

public enum PushMessage {
    /// Maps a peek event to an ntfy payload. Privacy rule: the body carries only
    /// the project (folder) name — plus the duration for `.finished` — never the
    /// session's message, tool, commands, or paths. The category rides in the title.
    public static func from(_ peek: PeekEvent) -> PushPayload {
        switch peek {
        case .needsYou(let session):
            return PushPayload(title: "Claude needs you", body: session.projectName,
                               priority: .urgent, tags: ["eyes"])
        case .finished(let session, let duration):
            return PushPayload(title: "Finished",
                               body: "\(session.projectName) · \(DurationFormat.short(duration))",
                               priority: .high, tags: ["white_check_mark"])
        }
    }
}
