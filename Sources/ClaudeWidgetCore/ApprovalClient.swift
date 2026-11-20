import Foundation

public enum ApprovalOutcome: Equatable, Sendable {
    case noDecision, allow, deny
}

/// The hook's side of the approval socket. Blocking, no threads; every wait has a deadline.
/// Returns `.allow`/`.deny` only after an ack and an explicit decision from a same-uid peer.
public enum ApprovalClient {
    public static func run(socketPath: String, request: ApprovalRequest,
                           ackTimeout: TimeInterval = WidgetConstants.approvalAckTimeout,
                           decisionTimeout: TimeInterval = WidgetConstants.approvalDecisionTimeout) -> ApprovalOutcome {
        guard let fd = UnixSocket.connect(path: socketPath) else { return .noDecision }
        defer { UnixSocket.close(fd) }
        // Sending the request and waiting for the ack share one ackTimeout budget.
        let start = DispatchTime.now().uptimeNanoseconds
        guard UnixSocket.peerUID(fd) == getuid(),
              UnixSocket.write(fd, ApprovalWire.encode(request), timeout: ackTimeout) else { return .noDecision }
        let spent = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        let reader = LineReader(fd: fd)
        guard let ackLine = reader.next(timeout: max(0, ackTimeout - spent)),
              ApprovalWire.decodeReply(ackLine) == .ack,
              let decisionLine = reader.next(timeout: decisionTimeout) else { return .noDecision }
        switch ApprovalWire.decodeReply(decisionLine) {
        case .allow: return .allow
        case .deny: return .deny
        default: return .noDecision
        }
    }
}
