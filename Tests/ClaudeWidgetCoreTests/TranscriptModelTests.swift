import XCTest
@testable import ClaudeWidgetCore

final class TranscriptModelTests: XCTestCase {
    func testUsesTheLastReplysModel() {
        // A /model switch mid-session: the newest reply wins.
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#,
            #"{"type":"user","message":{}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5"}}"#,
        ]
        XCTAssertEqual(TranscriptModel.latest(fromTranscriptLines: lines), "claude-sonnet-5-5")
    }

    func testSkipsSyntheticReplies() {
        // Claude Code writes "<synthetic>" for placeholder replies (errors, interruptions).
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>"}}"#,
        ]
        XCTAssertEqual(TranscriptModel.latest(fromTranscriptLines: lines), "claude-opus-5-5")
    }

    func testSkipsSidechainSubagentReplies() {
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5"}}"#,
        ]
        XCTAssertEqual(TranscriptModel.latest(fromTranscriptLines: lines), "claude-opus-5-5")
    }

    func testIgnoresAModelNamedInsideAnotherRecord() {
        // A user record with a model field, quoting an assistant line in its content.
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#,
            #"{"type":"user","message":{"model":"claude-haiku-5-5","content":"{\"type\":\"assistant\",\"message\":{\"model\":\"claude-haiku-5-5\"}}"}}"#,
        ]
        XCTAssertEqual(TranscriptModel.latest(fromTranscriptLines: lines), "claude-opus-5-5")
    }

    func testReturnsNilWithoutAUsableReply() {
        XCTAssertNil(TranscriptModel.latest(fromTranscriptLines: []))
        XCTAssertNil(TranscriptModel.latest(fromTranscriptLines: [
            #"{"type":"user","message":{}}"#,
            "garbage",
            #"{"type":"assistant","message":{"model":""}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>"}}"#,
        ]))
    }
}
