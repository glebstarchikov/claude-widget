import Foundation
import ClaudeWidgetCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(0) }
let event = arguments[1]

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = HookPayload(json: input) else { exit(0) }

let store = StateStore(directory: WidgetConstants.stateDir)
let previous = store.read(sessionId: payload.sessionId)
let update = EventMapper.map(event: event, payload: payload, previous: previous,
                             now: Date().timeIntervalSince1970)
try? store.apply(update)
exit(0)
