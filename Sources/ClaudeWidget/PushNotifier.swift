import Foundation
import ClaudeWidgetCore

/// Best-effort ntfy push for interruption-worthy peeks. Reads config from the
/// same UserDefaults as the notch toggles. Fire-and-forget: any failure is
/// swallowed, so a missed alert never perturbs the app or Claude.
struct PushNotifier {
    var defaults: UserDefaults = .standard

    private var enabled: Bool { defaults.bool(forKey: "pushEnabled") }
    private var topic: String { defaults.string(forKey: "pushTopic") ?? "" }
    private var server: String { defaults.string(forKey: "pushServer") ?? "https://ntfy.sh" }

    func send(_ peek: PeekEvent) {
        guard enabled, !topic.isEmpty else { return }
        post(PushMessage.from(peek))
    }

    /// Manual confirmation alert from Settings → Phone → "Send test notification".
    func sendTest() {
        guard !topic.isEmpty else { return }
        post(PushPayload(title: "Claude Widget", body: "Test alert · it works",
                         priority: .default, tags: ["bell"]))
    }

    private func post(_ payload: PushPayload) {
        guard let request = PushRequest.make(payload: payload, server: server, topic: topic) else { return }
        URLSession.shared.dataTask(with: request).resume()
    }
}
