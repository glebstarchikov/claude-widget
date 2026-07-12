import Foundation
import ClaudeWidgetCore

@MainActor
final class SessionMonitor {
    private let store = StateStore(directory: WidgetConstants.stateDir)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: DispatchWorkItem?
    private var gcTimer: Timer?

    private(set) var sessions: [Session] = []
    var onChange: (([Session], [Session], [PeekEvent]) -> Void)?

    private var subagentDir: URL {
        WidgetConstants.stateDir.appendingPathComponent("subagents", isDirectory: true)
    }

    func start() {
        // Watch the session dir AND the subagents subdir: kqueue vnode events
        // don't propagate from a subdirectory to its parent, so a subagent
        // write would never wake a watcher on stateDir alone.
        for dir in [WidgetConstants.stateDir, subagentDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            watch(dir)
        }

        gcTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.gcInterval,
                                       repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    private func watch(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reload() {
        let now = Date().timeIntervalSince1970
        let new = store.loadAll(now: now)
        let old = sessions
        sessions = new
        let peeks = Aggregator.peekEvents(old: old, new: new, now: now)
        onChange?(old, new, peeks)
    }
}
