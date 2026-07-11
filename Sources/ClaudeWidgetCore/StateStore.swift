import Foundation

public struct StateStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent("\(sessionId).json")
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
            let tmp = directory.appendingPathComponent(".\(session.sessionId).tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(fileURL(for: session.sessionId), withItemAt: tmp)
        }
    }

    public func read(sessionId: String) -> Session? {
        guard let data = try? Data(contentsOf: fileURL(for: sessionId)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func loadAll(now: Double) -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var sessions: [Session] = []
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
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }
}
