import XCTest
@testable import ClaudeWidgetCore

final class PushRequestTests: XCTestCase {
    private let payload = PushPayload(title: "Claude needs you", body: "claude-widget",
                                      priority: .urgent, tags: ["eyes"])

    func testBuildsPostToServerTopic() {
        let r = PushRequest.make(payload: payload, server: "https://ntfy.sh", topic: "claude-abc123")
        XCTAssertEqual(r?.url?.absoluteString, "https://ntfy.sh/claude-abc123")
        XCTAssertEqual(r?.httpMethod, "POST")
    }

    func testSetsHeadersAndBody() {
        let r = PushRequest.make(payload: payload, server: "https://ntfy.sh", topic: "t")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Title"), "Claude needs you")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Priority"), "urgent")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Tags"), "eyes")
        XCTAssertEqual(r?.httpBody, Data("claude-widget".utf8))
    }

    func testTrailingSlashServerNormalized() {
        let r = PushRequest.make(payload: payload, server: "https://ntfy.sh/", topic: "t")
        XCTAssertEqual(r?.url?.absoluteString, "https://ntfy.sh/t")
    }
}
