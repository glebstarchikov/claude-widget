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

    func testColumnsBelowOneClampToOne() {
        XCTAssertEqual(rows("abc", 0), ["a", "b", "c"])
    }
}
