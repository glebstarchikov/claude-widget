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

/// Asks the widget app to decide a permission request. Prints Claude Code's
/// decision JSON on allow/deny; prints nothing (falls through to the normal
/// prompt) when the app is absent, slow, or gives no explicit answer.
@discardableResult
func askWidgetForDecision(payload: HookPayload, ownerBundleId: String?) -> ApprovalOutcome {
    guard !ApprovalPolicy.hookSkips(toolName: payload.toolName ?? "") else { return .noDecision }
    let request = ApprovalRequest(payload: payload, ownerBundleId: ownerBundleId, id: UUID().uuidString)
    let outcome = ApprovalClient.run(socketPath: WidgetConstants.approvalSocket.path, request: request)
    switch outcome {
    case .allow: print(HookDecision.allowJSON)
    case .deny: print(HookDecision.denyJSON)
    case .noDecision: break
    }
    return outcome
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
    if event == "PermissionRequest" {
        askWidgetForDecision(payload: payload, ownerBundleId: ProcessInfo.processInfo.environment["__CFBundleIdentifier"])
    }
} else {
    let previous = store.read(sessionId: payload.sessionId)
    var update = EventMapper.map(event: event, payload: payload, previous: previous, now: now)
    // Tag the session with the app that launched it (Terminal, Cursor, the
    // Claude desktop app, …) so clicking it in the popover can jump there.
    if case .write(var session) = update {
        session.ownerBundleId = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        if let path = payload.transcriptPath, let lines = readTranscriptTail(path) {
            if let ctx = ContextUsage.tokens(fromTranscriptLines: lines) {
                session.contextTokens = ctx
            }
            // Only startup's SessionStart reports the model, and that report wins;
            // otherwise the newest reply's model covers resumes and /model switches.
            if payload.model == nil, let model = TranscriptModel.latest(fromTranscriptLines: lines) {
                session.model = model
            }
        }
        update = .write(session)
    }
    try? store.apply(update)
    if event == "PermissionRequest" {
        let outcome = askWidgetForDecision(payload: payload, ownerBundleId: ProcessInfo.processInfo.environment["__CFBundleIdentifier"])
        // Answered from the notch: Claude carries on, so the session stops needing you
        // now (written before exiting, so before Claude's next hook for this session).
        if outcome != .noDecision {
            try? store.apply(EventMapper.notchAnswered(allowed: outcome == .allow, payload: payload,
                                                       previous: store.read(sessionId: payload.sessionId),
                                                       now: Date().timeIntervalSince1970))
        }
    }
}
exit(0)
