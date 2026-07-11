import XCTest
@testable import ClaudeWidgetCore

final class StateStoreTests: XCTestCase {
    var dir: URL!
    var store: StateStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-tests-\(UUID().uuidString)", isDirectory: true)
        store = StateStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func session(_ id: String, state: SessionState = .working, updatedAt: Double) -> Session {
        Session(sessionId: id, state: state, cwd: "/tmp/proj", updatedAt: updatedAt)
    }

    func testWriteThenReadRoundTrip() throws {
        let s = session("s1", updatedAt: 100)
        try store.apply(.write(s))
        XCTAssertEqual(store.read(sessionId: "s1"), s)
    }

    func testRemoveDeletesFile() throws {
        try store.apply(.write(session("s1", updatedAt: 100)))
        try store.apply(.remove(sessionId: "s1"))
        XCTAssertNil(store.read(sessionId: "s1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "s1").path))
    }

    func testRemoveNonexistentDoesNotThrow() {
        XCTAssertNoThrow(try store.apply(.remove(sessionId: "ghost")))
    }

    func testIgnoreIsNoOp() throws {
        try store.apply(.ignore)
        XCTAssertEqual(store.loadAll(now: 0), [])
    }

    func testLoadAllSortsByUpdatedAtDescending() throws {
        try store.apply(.write(session("old", updatedAt: 100)))
        try store.apply(.write(session("new", updatedAt: 200)))
        XCTAssertEqual(store.loadAll(now: 300).map(\.sessionId), ["new", "old"])
    }

    func testLoadAllDeletesCorruptFiles() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("bad.json")
        try "{ not json".data(using: .utf8)!.write(to: bad)
        XCTAssertEqual(store.loadAll(now: 0), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
    }

    func testLoadAllGarbageCollectsStaleSessions() throws {
        let now: Double = 1_000_000
        try store.apply(.write(session("fresh", updatedAt: now - 60)))
        try store.apply(.write(session("stale", updatedAt: now - WidgetConstants.staleAfter - 1)))
        XCTAssertEqual(store.loadAll(now: now).map(\.sessionId), ["fresh"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "stale").path))
    }

    func testLoadAllOnMissingDirectoryReturnsEmpty() {
        XCTAssertEqual(store.loadAll(now: 0), [])
    }
}
