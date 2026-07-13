import XCTest
@testable import ClaudeWidgetCore

final class DurationFormatTests: XCTestCase {
    func testSecondsOnly() { XCTAssertEqual(DurationFormat.short(45), "45s") }
    func testZero() { XCTAssertEqual(DurationFormat.short(0), "0s") }
    func testMinutesAndSeconds() { XCTAssertEqual(DurationFormat.short(260), "4m 20s") }
    func testExactMinute() { XCTAssertEqual(DurationFormat.short(60), "1m 0s") }
    func testNegativeClampsToZero() { XCTAssertEqual(DurationFormat.short(-5), "0s") }
}
