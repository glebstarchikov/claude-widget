import Foundation

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case ready, working, needsYou, waiting
}

/// A subagent running under a session. Tracked in its own state file so the
/// parent session and its concurrently-running subagents never write the same
/// file at once.
public struct Subagent: Codable, Equatable, Sendable {
    public var agentId: String
    public var agentType: String
    public var tool: String?
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentType = "agent_type"
        case tool
        case updatedAt = "updated_at"
    }

    public init(agentId: String, agentType: String, tool: String? = nil, updatedAt: Double) {
        self.agentId = agentId
        self.agentType = agentType
        self.tool = tool
        self.updatedAt = updatedAt
    }
}

/// The on-disk record for a subagent, tagged with its parent session id so the
/// store can group subagents under their session.
public struct SubagentRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    public var agentId: String
    public var agentType: String
    public var tool: String?
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case tool
        case updatedAt = "updated_at"
    }

    public init(sessionId: String, agentId: String, agentType: String,
                tool: String? = nil, updatedAt: Double) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentType = agentType
        self.tool = tool
        self.updatedAt = updatedAt
    }

    public var subagent: Subagent {
        Subagent(agentId: agentId, agentType: agentType, tool: tool, updatedAt: updatedAt)
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var sessionId: String
    public var state: SessionState
    public var cwd: String
    public var message: String?
    public var model: String?
    public var title: String?
    public var tool: String?
    public var workingSince: Double?
    public var updatedAt: Double
    /// Assembled at load time from the subagent files; never serialized here.
    public var subagents: [Subagent] = []

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state, cwd, message, model, title, tool
        case workingSince = "working_since"
        case updatedAt = "updated_at"
    }

    public init(sessionId: String, state: SessionState, cwd: String,
                message: String? = nil, model: String? = nil, title: String? = nil,
                tool: String? = nil, workingSince: Double? = nil, updatedAt: Double,
                subagents: [Subagent] = []) {
        self.sessionId = sessionId
        self.state = state
        self.cwd = cwd
        self.message = message
        self.model = model
        self.title = title
        self.tool = tool
        self.workingSince = workingSince
        self.updatedAt = updatedAt
        self.subagents = subagents
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }
}

public enum AggregateState: Equatable, Sendable {
    case asleep, ready, waiting, working, needsYou
}
