import XCTest
@testable import ClaudeWidgetCore

final class ApprovalLayoutTests: XCTestCase {
    private func rows(_ text: String, _ columns: Int) -> [String] {
        ApprovalLayout.pieces(text, columns: columns).map(\.text)
    }

    func testRealNewlineAndSoftWrapAreDistinguishable() {
        // Same characters on screen; one runs `rm -rf ~/`, the other doesn't.
        let newline = ApprovalLayout.pieces("&& rm -rf ~/\nold-builds", columns: 12)
        let wrapped = ApprovalLayout.pieces("&& rm -rf ~/old-builds", columns: 12)
        XCTAssertEqual(newline.map(\.text), ["&& rm -rf ~/", "old-builds"])
        XCTAssertEqual(wrapped.map(\.text), ["&& rm -rf ~/", "old-builds"])
        XCTAssertEqual(newline.map(\.continuation), [false, false])
        XCTAssertEqual(wrapped.map(\.continuation), [false, true])
        XCTAssertNotEqual(newline, wrapped)
    }

    func testEdgeSpacesAreFlagged() {
        // "--force-with-" + "lease" vs "--force-with- lease": the space lands at a row edge.
        let spaced = ApprovalLayout.pieces("--force-with- lease", columns: 14)
        XCTAssertEqual(spaced.map(\.text), ["--force-with- ", "lease"])
        XCTAssertTrue(spaced[0].trailingSpace)
        XCTAssertEqual(spaced[0].middle, "--force-with-")
        let leading = ApprovalLayout.pieces("--force-with- lease", columns: 13)
        XCTAssertEqual(leading.map(\.text), ["--force-with-", " lease"])
        XCTAssertFalse(leading[0].trailingSpace)
        XCTAssertTrue(leading[1].leadingSpace)
        XCTAssertEqual(leading[1].middle, "lease")
        let unspaced = ApprovalLayout.pieces("--force-with-lease", columns: 13)
        XCTAssertFalse(unspaced.contains { $0.leadingSpace || $0.trailingSpace })
    }

    func testSpaceOnlyPiecesMarkEachSpaceOnce() {
        let one = ApprovalLayout.pieces(" ", columns: 5)[0]
        XCTAssertTrue(one.leadingSpace)
        XCTAssertFalse(one.trailingSpace)
        XCTAssertEqual(one.middle, "")
        let two = ApprovalLayout.pieces("  ", columns: 5)[0]
        XCTAssertTrue(two.leadingSpace && two.trailingSpace)
        XCTAssertEqual(two.middle, "")
        // Interior spaces stay as they are.
        XCTAssertEqual(ApprovalLayout.pieces("a  b", columns: 9)[0].middle, "a  b")
    }

    func testExactColumnBoundary() {
        XCTAssertEqual(rows(String(repeating: "x", count: 10), 10), [String(repeating: "x", count: 10)])
        XCTAssertEqual(rows(String(repeating: "x", count: 11), 10), [String(repeating: "x", count: 10), "x"])
        XCTAssertEqual(rows(String(repeating: "x", count: 20), 10).count, 2)   // no empty third row
        XCTAssertEqual(ApprovalLayout.pieces(String(repeating: "x", count: 11), columns: 10).map(\.continuation),
                       [false, true])
    }

    func testEmptyLinesAreKept() {
        XCTAssertEqual(rows("", 10), [""])
        XCTAssertEqual(rows("a\n\nb", 10), ["a", "", "b"])
        XCTAssertEqual(rows("a\n", 10), ["a", ""])
        XCTAssertFalse(ApprovalLayout.pieces("a\n\nb", columns: 10).contains { $0.continuation })
    }

    func testAllowNeedsMeasuredRoomyColumns() {
        XCTAssertFalse(ApprovalLayout.canOfferAllow(columns: nil), "not measured yet")
        XCTAssertFalse(ApprovalLayout.canOfferAllow(columns: -2), "measured at ~0 pt")
        XCTAssertFalse(ApprovalLayout.canOfferAllow(columns: 0))
        XCTAssertFalse(ApprovalLayout.canOfferAllow(columns: 7))
        XCTAssertTrue(ApprovalLayout.canOfferAllow(columns: 8))
        XCTAssertTrue(ApprovalLayout.canOfferAllow(columns: 62))
    }

    func testRowMovementIgnoresAppearingAndJitter() {
        XCTAssertFalse(ApprovalLayout.rowMoved(from: nil, to: 120), "appearing isn't moving")
        XCTAssertFalse(ApprovalLayout.rowMoved(from: 120, to: 120))
        XCTAssertFalse(ApprovalLayout.rowMoved(from: 120, to: 120.6), "sub-point jitter")
        XCTAssertFalse(ApprovalLayout.rowMoved(from: 120, to: 119.01))
        XCTAssertTrue(ApprovalLayout.rowMoved(from: 120, to: 121))
        XCTAssertTrue(ApprovalLayout.rowMoved(from: 120, to: 84), "a row inserted above")
    }

    func testColumnsBelowOneClampToOne() {
        XCTAssertEqual(rows("abc", 0), ["a", "b", "c"])
    }
}
