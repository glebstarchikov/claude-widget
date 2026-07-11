import XCTest
@testable import ClaudeWidgetCore

final class SessionTests: XCTestCase {
    func testCodableRoundTripWithSnakeCaseKeys() throws {
        let session = Session(sessionId: "abc", state: .needsYou, cwd: "/Users/gleb/claude-widget",
                              message: "Bash", workingSince: 100.5, updatedAt: 200.0)
        let data = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["session_id"] as? String, "abc")
        XCTAssertEqual(json["working_since"] as? Double, 100.5)
        XCTAssertEqual(json["state"] as? String, "needsYou")
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    func testProjectName() {
        let session = Session(sessionId: "a", state: .ready, cwd: "/Users/gleb/my-project", updatedAt: 0)
        XCTAssertEqual(session.projectName, "my-project")
    }
}
