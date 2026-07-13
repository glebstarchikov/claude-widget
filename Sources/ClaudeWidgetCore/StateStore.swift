import Foundation

public struct StateStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent("\(sessionId).json")
    }

    public var subagentDir: URL {
        directory.appendingPathComponent("subagents", isDirectory: true)
    }

    func subagentURL(_ agentId: String) -> URL {
        subagentDir.appendingPathComponent("\(agentId).json")
    }

    public func apply(_ update: SessionUpdate) throws {
        switch update {
        case .ignore:
            return
        case .remove(let id):
            try? FileManager.default.removeItem(at: fileURL(for: id))
        case .write(let session):
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            let tmp = directory.appendingPathComponent(".\(session.sessionId).\(UUID().uuidString).tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(fileURL(for: session.sessionId), withItemAt: tmp)
        }
    }

    public func applySubagent(_ update: SubagentUpdate) throws {
        switch update {
        case .ignore:
            return
        case .remove(let agentId):
            try? FileManager.default.removeItem(at: subagentURL(agentId))
        case .write(let record):
            try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            let tmp = subagentDir.appendingPathComponent(".\(record.agentId).\(UUID().uuidString).tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(subagentURL(record.agentId), withItemAt: tmp)
        }
    }

    public func read(sessionId: String) -> Session? {
        guard let data = try? Data(contentsOf: fileURL(for: sessionId)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func readSubagent(agentId: String) -> SubagentRecord? {
        guard let data = try? Data(contentsOf: subagentURL(agentId)) else { return nil }
        return try? JSONDecoder().decode(SubagentRecord.self, from: data)
    }

    /// Loads all live sessions, each with its subagents attached, sorted newest
    /// first. Doubles as the periodic GC sweep: stale files and files that fail to
    /// decode are removed here. Treating decode failures as corrupt-and-disposable
    /// is safe today because writes are atomic (a reader never sees a half-written
    /// file) — but note a future breaking schema change would discard live session
    /// files rather than migrate them.
    public func loadAll(now: Double) -> [Session] {
        var sessions: [Session] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let session = try? JSONDecoder().decode(Session.self, from: data) else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                if now - session.updatedAt > WidgetConstants.staleAfter {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                sessions.append(session)
            }
        }

        let byParent = Dictionary(grouping: loadSubagents(now: now), by: \.sessionId)
        for index in sessions.indices {
            sessions[index].subagents = (byParent[sessions[index].sessionId] ?? [])
                .map(\.subagent)
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadSubagents(now: Double) -> [SubagentRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: subagentDir, includingPropertiesForKeys: nil) else { return [] }
        var records: [SubagentRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(SubagentRecord.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if now - record.updatedAt > WidgetConstants.staleAfter {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            records.append(record)
        }
        return records
    }
}
