import XCTest
@testable import ClaudeWidgetCore

final class ContextUsageTests: XCTestCase {
    func testSumsInputAndCacheTokens() {
        let lines = [
            #"{"type":"user","message":{}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":100}}}"#,
        ]
        XCTAssertEqual(ContextUsage.tokens(fromTranscriptLines: lines), 115)
    }

    func testUsesTheLastAssistantTurn() {
        let lines = [
            #"{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":200}}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":2,"cache_read_input_tokens":400}}}"#,
        ]
        XCTAssertEqual(ContextUsage.tokens(fromTranscriptLines: lines), 402)
    }

    func testSkipsSidechainSubagentTurns() {
        let lines = [
            #"{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":300}}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":1,"cache_read_input_tokens":9999}}}"#,
        ]
        XCTAssertEqual(ContextUsage.tokens(fromTranscriptLines: lines), 301)
    }

    func testReturnsNilWhenNoAssistantUsage() {
        XCTAssertNil(ContextUsage.tokens(fromTranscriptLines: [#"{"type":"user","message":{}}"#, "garbage"]))
    }
}
