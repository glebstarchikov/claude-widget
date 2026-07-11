import Foundation
import ClaudeWidgetCore

@MainActor
final class SessionMonitor {
    private let store = StateStore(directory: WidgetConstants.stateDir)
    private var source: DispatchSourceFileSystemObject?
    private var directoryDescriptor: CInt = -1
    private var debounce: DispatchWorkItem?
    private var gcTimer: Timer?

    private(set) var sessions: [Session] = []
    var onChange: (([Session], [Session], [PeekEvent]) -> Void)?

    func start() {
        try? FileManager.default.createDirectory(at: WidgetConstants.stateDir,
                                                 withIntermediateDirectories: true)
        directoryDescriptor = open(WidgetConstants.stateDir.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { [directoryDescriptor] in close(directoryDescriptor) }
        source.resume()
        self.source = source

        gcTimer = Timer.scheduledTimer(withTimeInterval: WidgetConstants.gcInterval,
                                       repeats: true) { _ in
            Task { @MainActor in self.reload() }
        }
        reload()
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
