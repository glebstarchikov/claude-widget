import Foundation
import ClaudeWidgetCore

/// Reads the tail of a transcript file as lines, dropping the possibly-partial
/// first line. Bounded so we never load a multi-MB transcript on every event.
func readTranscriptTail(_ path: String, maxBytes: UInt64 = 1_048_576) -> [String]? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    let start = end > maxBytes ? end - maxBytes : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return nil }
    var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(0) }
let event = arguments[1]

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = HookPayload(json: input) else { exit(0) }

let store = StateStore(directory: WidgetConstants.stateDir)
let now = Date().timeIntervalSince1970

if let agentId = payload.agentId {
    // Subagent event (has agent_id): tracked in its own file so it never races
    // the parent session's file.
    let previous = store.readSubagent(agentId: agentId)
    try? store.applySubagent(EventMapper.mapSubagent(event: event, payload: payload, previous: previous, now: now))
} else {
    let previous = store.read(sessionId: payload.sessionId)
    var update = EventMapper.map(event: event, payload: payload, previous: previous, now: now)
    // Tag the session with the app that launched it (Terminal, Cursor, the
    // Claude desktop app, …) so clicking it in the popover can jump there.
    if case .write(var session) = update {
        session.ownerBundleId = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        if let path = payload.transcriptPath,
           let lines = readTranscriptTail(path),
           let ctx = ContextUsage.tokens(fromTranscriptLines: lines) {
            session.contextTokens = ctx
        }
        update = .write(session)
    }
    try? store.apply(update)
}
exit(0)
