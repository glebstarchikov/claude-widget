import Foundation
import ClaudeWidgetCore

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
        update = .write(session)
    }
    try? store.apply(update)
}
exit(0)
