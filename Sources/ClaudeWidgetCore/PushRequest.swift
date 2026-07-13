import Foundation

public enum PushRequest {
    /// Builds the ntfy publish request: POST <server>/<topic>, message in the body,
    /// Title/Priority/Tags in headers. Returns nil if the URL can't be formed.
    public static func make(payload: PushPayload, server: String, topic: String) -> URLRequest? {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard let url = URL(string: "\(base)/\(topic)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(payload.title, forHTTPHeaderField: "Title")
        request.setValue(payload.priority.rawValue, forHTTPHeaderField: "Priority")
        request.setValue(payload.tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        request.httpBody = Data(payload.body.utf8)
        return request
    }
}
