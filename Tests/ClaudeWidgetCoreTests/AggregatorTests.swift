import XCTest
@testable import ClaudeWidgetCore

final class AggregatorTests: XCTestCase {
    private func session(_ id: String, _ state: SessionState, workingSince: Double? = nil) -> Session {
        Session(sessionId: id, state: state, cwd: "/tmp/proj", workingSince: workingSince, updatedAt: 0)
    }

    func testAggregatePriority() {
        XCTAssertEqual(Aggregator.aggregate([]), .asleep)
        XCTAssertEqual(Aggregator.aggregate([session("a", .ready)]), .ready)
        XCTAssertEqual(Aggregator.aggregate([session("a", .ready), session("b", .waiting)]), .waiting)
        XCTAssertEqual(Aggregator.aggregate([session("a", .waiting), session("b", .working)]), .working)
        XCTAssertEqual(Aggregator.aggregate([session("a", .working), session("b", .needsYou)]), .needsYou)
    }

    func testNeedsYouPeekFiresOnlyOnTransition() {
        let before = [session("a", .working)]
        let after = [session("a", .needsYou)]
        XCTAssertEqual(Aggregator.peekEvents(old: before, new: after, now: 100), [.needsYou(after[0])])
        XCTAssertEqual(Aggregator.peekEvents(old: after, new: after, now: 100), [], "no repeat while state persists")
    }

    func testNeedsYouPeekFiresForBrandNewSession() {
        let after = [session("a", .needsYou)]
        XCTAssertEqual(Aggregator.peekEvents(old: [], new: after, now: 100), [.needsYou(after[0])])
    }

    func testFinishedPeekRequiresLongWorkingStretch() {
        let now: Double = 1000
        let longRun = [session("a", .working, workingSince: now - 61)]
        let shortRun = [session("a", .working, workingSince: now - 59)]
        let stopped = [session("a", .waiting, workingSince: now - 61)]

        XCTAssertEqual(Aggregator.peekEvents(old: longRun, new: stopped, now: now),
                       [.finished(stopped[0], duration: 61)])
        XCTAssertEqual(Aggregator.peekEvents(old: shortRun, new: stopped, now: now), [],
                       "under 60 s stays quiet")
        XCTAssertEqual(Aggregator.peekEvents(old: stopped, new: stopped, now: now), [],
                       "waiting to waiting fires nothing")
    }
}
