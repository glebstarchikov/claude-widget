import Foundation

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case ready, working, needsYou, waiting
}

public struct Session: Codable, Equatable, Sendable {
    public var sessionId: String
    public var state: SessionState
    public var cwd: String
    public var message: String?
    public var workingSince: Double?
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state, cwd, message
        case workingSince = "working_since"
        case updatedAt = "updated_at"
    }

    public init(sessionId: String, state: SessionState, cwd: String,
                message: String? = nil, workingSince: Double? = nil, updatedAt: Double) {
        self.sessionId = sessionId
        self.state = state
        self.cwd = cwd
        self.message = message
        self.workingSince = workingSince
        self.updatedAt = updatedAt
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }
}

public enum AggregateState: Equatable, Sendable {
    case asleep, ready, waiting, working, needsYou
}
