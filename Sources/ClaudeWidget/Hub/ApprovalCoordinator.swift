import AppKit
import os
import ClaudeWidgetCore

/// Decides what happens to each permission request the hook forwards (spec §8):
/// pass it straight back to Claude Code's own prompt, or ack it and hold it in
/// `HubModel.pending` until Gleb answers, his attention moves to the session's
/// app, Claude moves on, or 30 s pass.
///
/// Nothing here approves anything by itself: `.allow` is sent only from
/// `answer(id:allow:)`, which only the Allow buttons call.
@MainActor
final class ApprovalCoordinator {
    private enum Ending {
        case answered(allow: Bool), ownerActive, timedOut, closed, sessionMovedOn, settingOff, noPill

        var label: String {
            switch self {
            case .answered(let allow): return allow ? "allowed" : "denied"
            case .ownerActive: return "passed: owner app active"
            case .timedOut: return "passed: timed out"
            case .closed: return "dropped: hook hung up"
            case .sessionMovedOn: return "passed: session moved on"
            case .settingOff: return "passed: setting off"
            case .noPill: return "passed: no pill"
            }
        }
    }

    /// Allow is ignored this soon after the pending list changed: a click aimed at
    /// one request (or a double-click) must not land on another that slid into
    /// its place. Deny is fail-safe and stays immediate.
    private static let allowSettle: TimeInterval = 0.5

    private let model: HubModel
    private let appModel: AppModel
    private let server = ApprovalServer(path: WidgetConstants.approvalSocket.path)
    private var replies: [String: ApprovalServer.Reply] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    /// Main-loop requests whose session has shown up in `model.sessions`.
    private var sessionSeen: Set<String> = []
    /// When `model.pending` last gained or lost a request.
    private var queueChangedAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    /// `--auto-answer allow|deny`, for verification only (see `scheduleAutoAnswer`).
    private let autoAnswer: Bool?

    /// Called after `model.pending` changes. `dismissing` names the session of a
    /// request Gleb dealt with (answered, or went to its app): its pill goes too.
    var onChange: ((_ dismissing: String?) -> Void)?

    init(model: HubModel, appModel: AppModel) {
        self.model = model
        self.appModel = appModel
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--auto-answer"), i + 1 < args.count, ["allow", "deny"].contains(args[i + 1]) {
            autoAnswer = args[i + 1] == "allow"
        } else {
            autoAnswer = nil
        }
    }

    func start() {
        if let autoAnswer {
            Logger.approval.notice("auto-answer \(autoAnswer ? "allow" : "deny", privacy: .public) is on for sim- sessions")
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(bundleId) }
        })
        server.start { [weak self] request, reply in
            guard let self else { reply(.pass); return {} }
            return self.receive(request, reply: reply)
        }
    }

    /// App quit: unlinks the socket and hangs up on every waiting hook.
    func stop() {
        server.stop()
    }

    /// Allow/Deny from the pill or a row. Allow is honored only where a row would
    /// offer it (`ApprovalPolicy.action`), and not within `allowSettle` of the
    /// pending list changing; anything else can only be denied.
    func answer(id: String, allow: Bool) {
        guard let approval = model.pending.first(where: { $0.id == id }) else { return }
        if allow {
            guard ApprovalPolicy.action(for: approval.presentation, on: .row) == .allow else {
                Logger.approval.error("allow refused: not offered for this request")
                return
            }
            guard Date().timeIntervalSince(queueChangedAt) >= Self.allowSettle else {
                Logger.approval.notice("allow ignored: requests changed under the pointer")
                return
            }
        }
        end(id, .answered(allow: allow))
    }

    /// The setting was switched off: everything pending goes back to Claude Code.
    func settingChanged(enabled: Bool) {
        guard !enabled else { return }
        endAll(.settingOff)
    }

    /// The hub closed. With proactive alerts off no pill takes over, so nothing
    /// would show the pending requests: they go back to Claude Code.
    func hubClosed() {
        guard !appModel.notchProactive else { return }
        endAll(.noPill)
    }

    /// Proactive alerts were switched off: with the hub closed, nothing shows the
    /// pending requests any more.
    func proactiveChanged(enabled: Bool) {
        guard !enabled, !model.expanded else { return }
        endAll(.noPill)
    }

    /// A main-loop request ends once its session leaves needs-you after the request
    /// arrived (Gleb answered elsewhere, or Claude moved on), or the session is gone.
    func sessionsChanged(_ sessions: [Session]) {
        for approval in model.pending where approval.request.agentId == nil {
            guard let session = sessions.first(where: { $0.sessionId == approval.request.sessionId }) else {
                if sessionSeen.contains(approval.id) { end(approval.id, .sessionMovedOn) }
                continue
            }
            sessionSeen.insert(approval.id)
            // A state older than the request is the monitor catching up, not a change.
            if session.state != .needsYou, session.updatedAt > approval.receivedAt.timeIntervalSince1970 {
                end(approval.id, .sessionMovedOn)
            }
        }
    }

    // MARK: - Rules

    private func receive(_ request: ApprovalRequest, reply: @escaping ApprovalServer.Reply) -> @MainActor () -> Void {
        // Pass straight back to Claude Code's prompt when this widget mustn't hold
        // it: an unknown protocol version, the setting off, a tool that isn't a
        // permission, an owner app we can't watch, or Gleb already in that app.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard request.v == 1,
              appModel.answerFromNotch,
              !ApprovalPolicy.hookSkips(toolName: request.toolName),
              let owner = request.ownerBundleId, !owner.isEmpty,
              owner != frontmost,
              replies[request.id] == nil
        else {
            reply(.pass)
            Logger.approval.notice("\(request.toolName, privacy: .public) passed on arrival")
            return {}
        }
        // Held requests must be on screen: the pill (proactive alerts) or the open hub.
        guard appModel.notchProactive || model.expanded else {
            reply(.pass)
            Logger.approval.notice("\(request.toolName, privacy: .public) passed: no pill")
            return {}
        }

        reply(.ack)
        let approval = PendingApproval(id: request.id, request: request,
                                       presentation: ApprovalPolicy.presentation(for: request),
                                       receivedAt: Date())
        replies[approval.id] = reply
        timers[approval.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WidgetConstants.approvalDecisionTimeout))
            if !Task.isCancelled { self?.end(approval.id, .timedOut) }
        }
        model.pending.append(approval)
        queueChangedAt = Date()
        Logger.approval.notice("\(request.toolName, privacy: .public) held for an answer")
        onChange?(nil)
        scheduleAutoAnswer(approval)
        return { [weak self] in self?.end(approval.id, .closed) }
    }

    /// The moment a request's owning app comes to the front, its own prompt takes over.
    private func appActivated(_ bundleId: String?) {
        guard let bundleId else { return }
        for approval in model.pending where approval.request.ownerBundleId == bundleId {
            end(approval.id, .ownerActive)
        }
    }

    /// Removes a request and sends its final reply (none once the hook hung up).
    private func end(_ id: String, _ ending: Ending) {
        guard let reply = replies.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        sessionSeen.remove(id)
        let sessionId = model.pending.first { $0.id == id }?.request.sessionId
        model.pending.removeAll { $0.id == id }
        queueChangedAt = Date()
        switch ending {
        case .answered(let allow): reply(allow ? .allow : .deny)
        case .closed: break
        case .ownerActive, .timedOut, .sessionMovedOn, .settingOff, .noPill: reply(.pass)
        }
        Logger.approval.notice("request \(ending.label, privacy: .public)")
        switch ending {
        case .answered, .ownerActive: onChange?(sessionId)
        default: onChange?(nil)
        }
    }

    private func endAll(_ ending: Ending) {
        for id in model.pending.map(\.id) { end(id, ending) }
    }

    /// Verification only. With `--auto-answer allow|deny` on the command line, a
    /// request from `scripts/simulate.sh` (session id "sim-…") is answered after
    /// 3 s through the same path as the buttons, and Allow only where the pill
    /// offers it. Requests from real Claude sessions are never auto-answered,
    /// and without the flag this does nothing.
    private func scheduleAutoAnswer(_ approval: PendingApproval) {
        guard let allow = autoAnswer, approval.request.sessionId.hasPrefix("sim-") else { return }
        if allow, ApprovalPolicy.action(for: approval.presentation, on: .pill) != .allow {
            Logger.approval.notice("auto-answer: the pill offers no Allow here")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.model.answerApproval(approval.id, allow)
        }
    }
}

extension ApprovalPresentation {
    var summary: String {
        switch self {
        case .allowable(let summary, _), .openOnly(let summary): return summary
        }
    }
}
