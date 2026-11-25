import XCTest
@testable import ClaudeWidgetCore

/// A downloaded app's files carry `com.apple.quarantine`, and Gatekeeper holds a
/// quarantined hook copied out of the approved bundle. These run in a temporary
/// folder and set the attribute themselves; nothing here executes a binary.
final class HookBinaryCopyTests: XCTestCase {
    private let quarantine = "com.apple.quarantine"
    private let quarantineValue = "0083;6745a1b2;Safari;"
    private var dir: URL!
    private var source: URL { dir.appendingPathComponent("bundle/claude-widget-hook") }
    private var destination: URL { dir.appendingPathComponent("bin/claude-widget-hook") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-hookcopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func setAttribute(_ name: String, _ value: String, on url: URL) throws {
        let bytes = Array(value.utf8)
        guard setxattr(url.path, name, bytes, bytes.count, 0, 0) == 0 else { throw POSIXError(.EIO) }
    }

    private func attribute(_ name: String, on url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &bytes, size, 0, 0) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - What must not change

    func testSourceInTheBundleKeepsItsQuarantine() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try HookBinaryCopy.install(from: source, to: destination)
        XCTAssertEqual(attribute(quarantine, on: source), quarantineValue)
    }

    func testOtherFileBesideTheCopyKeepsItsQuarantine() throws {
        let neighbor = destination.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: neighbor.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: neighbor)
        try setAttribute(quarantine, quarantineValue, on: neighbor)
        try setAttribute(quarantine, quarantineValue, on: source)
        try HookBinaryCopy.install(from: source, to: destination)
        XCTAssertEqual(attribute(quarantine, on: neighbor), quarantineValue)
    }

    func testCopyKeepsAttributesOtherThanQuarantine() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try setAttribute("com.example.keep", "yes", on: source)
        try HookBinaryCopy.install(from: source, to: destination)
        XCTAssertEqual(attribute("com.example.keep", on: destination), "yes")
    }

    func testSourceWithoutQuarantineCopiesWithoutError() throws {
        try HookBinaryCopy.install(from: source, to: destination)
        XCTAssertNil(attribute(quarantine, on: destination))
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testMissingSourceThrowsAndLeavesTheInstalledHookAndNoTemporaryFile() throws {
        try HookBinaryCopy.install(from: source, to: destination)
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try HookBinaryCopy.install(from: source, to: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["claude-widget-hook"])
    }

    // MARK: - What the copy fixes

    func testCopyLosesQuarantine() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try HookBinaryCopy.install(from: source, to: destination)
        XCTAssertNil(attribute(quarantine, on: destination))
    }

    func testCopyMatchesSourceByteForByteAndStaysExecutable() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try HookBinaryCopy.install(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
    }

    func testReplacesAQuarantinedInstalledHookAndLeavesNoTemporaryFile() throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        try setAttribute(quarantine, quarantineValue, on: destination)
        try setAttribute(quarantine, quarantineValue, on: source)
        try HookBinaryCopy.install(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertNil(attribute(quarantine, on: destination))
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["claude-widget-hook"])
    }
}
