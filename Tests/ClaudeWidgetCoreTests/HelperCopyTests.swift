import XCTest
@testable import ClaudeWidgetCore

/// A downloaded app's files carry `com.apple.quarantine`, and Gatekeeper holds a
/// quarantined hook or adapter copied out of the approved bundle. These run in a temporary
/// folder and set the attribute themselves; nothing here executes a binary.
/// `install` stamps the source first, as a fresh launch would.
final class HelperCopyTests: XCTestCase {
    private let quarantine = "com.apple.quarantine"
    private let quarantineValue = "0083;6745a1b2;Safari;"
    private var dir: URL!
    private var source: URL { dir.appendingPathComponent("bundle/claude-widget-hook") }
    private var destination: URL { dir.appendingPathComponent("bin/claude-widget-hook") }
    private var adapter: URL { dir.appendingPathComponent("bundle/libMediaRemoteAdapter.dylib") }
    private var adapterCopy: URL { dir.appendingPathComponent("bin/libMediaRemoteAdapter.dylib") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-hookcopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try Data((0..<2048).map { UInt8($0 % 241) }).write(to: adapter)
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

    /// Copies the way a freshly launched app does: stamp, then install.
    private func install(_ source: URL, _ destination: URL) throws {
        try HelperCopy.install(from: source, to: destination, launchStamp: LaunchStamp(of: source))
    }

    private func inode(_ url: URL) -> UInt64? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_ino : nil
    }

    private func leftInBin() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).sorted()
    }

    // MARK: - The bundle changed since launch: no copy, flag kept

    func testSourceReplacedSinceLaunchThrowsAndKeepsItsQuarantine() throws {
        try install(source, destination)
        let stamp = LaunchStamp(of: source)
        try FileManager.default.removeItem(at: source)
        try Data("a bundle nobody approved".utf8).write(to: source)
        try setAttribute(quarantine, quarantineValue, on: source)
        XCTAssertThrowsError(try HelperCopy.install(from: source, to: destination, launchStamp: stamp)) {
            XCTAssertEqual($0 as? HelperCopyError, .changedSinceLaunch)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data((0..<4096).map { UInt8($0 % 251) }))
        XCTAssertEqual(attribute(quarantine, on: source), quarantineValue)
        XCTAssertEqual(try leftInBin(), ["claude-widget-hook"])
    }

    func testSourceOverwrittenInPlaceSinceLaunchThrows() throws {
        let stamp = LaunchStamp(of: source)
        let before = inode(source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data((0..<4096).map { UInt8(($0 + 1) % 251) }))   // same size, same inode
        try handle.close()
        XCTAssertEqual(inode(source), before)
        XCTAssertThrowsError(try HelperCopy.install(from: source, to: destination, launchStamp: stamp))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSourceMissingAtLaunchThrows() throws {
        let missing = dir.appendingPathComponent("bundle/not-there")
        let stamp = LaunchStamp(of: missing)
        XCTAssertNil(stamp)
        try Data("appeared later".utf8).write(to: missing)
        XCTAssertThrowsError(try HelperCopy.install(from: missing, to: destination, launchStamp: stamp))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSymlinkSourceGetsNoStamp() throws {
        let link = dir.appendingPathComponent("bundle/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertNil(LaunchStamp(of: link))
    }

    // MARK: - What must not change

    func testSourceInTheBundleKeepsItsQuarantine() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try install(source, destination)
        XCTAssertEqual(attribute(quarantine, on: source), quarantineValue)
    }

    func testOtherFileBesideTheCopyKeepsItsQuarantine() throws {
        let neighbor = destination.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: neighbor.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: neighbor)
        try setAttribute(quarantine, quarantineValue, on: neighbor)
        try setAttribute(quarantine, quarantineValue, on: source)
        try install(source, destination)
        XCTAssertEqual(attribute(quarantine, on: neighbor), quarantineValue)
    }

    func testCopyKeepsAttributesOtherThanQuarantine() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try setAttribute("com.example.keep", "yes", on: source)
        try install(source, destination)
        XCTAssertEqual(attribute("com.example.keep", on: destination), "yes")
    }

    func testSourceWithoutQuarantineCopiesWithoutError() throws {
        try install(source, destination)
        XCTAssertNil(attribute(quarantine, on: destination))
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testMissingSourceThrowsAndLeavesTheInstalledHookAndNoTemporaryFile() throws {
        try install(source, destination)
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try install(source, destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try leftInBin(), ["claude-widget-hook"])
    }

    // MARK: - Atomic replace: a running hook or perl keeps the old file

    func testOpenHandleKeepsReadingTheOldCopyAndThePathGetsANewInode() throws {
        try install(source, destination)
        let old = try Data(contentsOf: destination)
        let before = inode(destination)
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        let newer = Data("a newer hook".utf8)
        try newer.write(to: source)
        try install(source, destination)
        XCTAssertEqual(try handle.readToEnd(), old)
        XCTAssertNotEqual(inode(destination), before)
        XCTAssertEqual(try Data(contentsOf: destination), newer)
    }

    func testSymlinkAtTheDestinationIsReplacedAndItsTargetIsUntouched() throws {
        let target = dir.appendingPathComponent("elsewhere/target")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not the widget's".utf8).write(to: target)
        try setAttribute(quarantine, quarantineValue, on: target)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        try install(source, destination)
        XCTAssertEqual(try Data(contentsOf: target), Data("not the widget's".utf8))
        XCTAssertEqual(attribute(quarantine, on: target), quarantineValue)
        XCTAssertNotNil(LaunchStamp(of: destination), "the destination is a regular file now")
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testInstalledPathNeverGoesMissingDuringAReplace() throws {
        try install(source, destination)
        final class Watch: @unchecked Sendable {
            let lock = NSLock(); var done = false; var misses = 0
        }
        let watch = Watch(), finished = DispatchSemaphore(value: 0), path = destination.path
        Thread {
            var st = stat()
            while true {
                watch.lock.lock(); let done = watch.done; watch.lock.unlock()
                if done { break }
                if lstat(path, &st) != 0 { watch.lock.lock(); watch.misses += 1; watch.lock.unlock() }
            }
            finished.signal()
        }.start()
        for _ in 0..<300 { try install(source, destination) }
        watch.lock.lock(); watch.done = true; watch.lock.unlock()
        finished.wait()
        XCTAssertEqual(watch.misses, 0)
    }

    // MARK: - What the copy fixes

    func testCopyLosesQuarantine() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try install(source, destination)
        XCTAssertNil(attribute(quarantine, on: destination))
    }

    func testCopyMatchesSourceByteForByteAndStaysExecutable() throws {
        try setAttribute(quarantine, quarantineValue, on: source)
        try install(source, destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
    }

    func testReplacesAQuarantinedInstalledHookAndLeavesNoTemporaryFile() throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        try setAttribute(quarantine, quarantineValue, on: destination)
        try setAttribute(quarantine, quarantineValue, on: source)
        try install(source, destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertNil(attribute(quarantine, on: destination))
        XCTAssertEqual(try leftInBin(), ["claude-widget-hook"])
    }

    // MARK: - The now-playing adapter: what must not change

    func testAdapterInTheBundleKeepsItsQuarantine() throws {
        try setAttribute(quarantine, quarantineValue, on: adapter)
        try install(adapter, adapterCopy)
        XCTAssertEqual(attribute(quarantine, on: adapter), quarantineValue)
    }

    func testCopyingTheAdapterLeavesTheInstalledHookAlone() throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("hook".utf8).write(to: destination)
        try setAttribute(quarantine, quarantineValue, on: destination)
        try setAttribute(quarantine, quarantineValue, on: adapter)
        try install(adapter, adapterCopy)
        XCTAssertEqual(try Data(contentsOf: destination), Data("hook".utf8))
        XCTAssertEqual(attribute(quarantine, on: destination), quarantineValue)
    }

    // MARK: - The now-playing adapter: first run and app updates

    func testAdapterCopyOnFirstRunCreatesTheFolderAndLosesQuarantine() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: adapterCopy.deletingLastPathComponent().path))
        try setAttribute(quarantine, quarantineValue, on: adapter)
        try install(adapter, adapterCopy)
        XCTAssertEqual(try Data(contentsOf: adapterCopy), try Data(contentsOf: adapter))
        XCTAssertNil(attribute(quarantine, on: adapterCopy))
    }

    func testAppUpdateReplacesTheAdapterCopy() throws {
        try install(adapter, adapterCopy)
        let updated = Data("a newer adapter".utf8)
        try updated.write(to: adapter)
        try setAttribute(quarantine, quarantineValue, on: adapter)
        try install(adapter, adapterCopy)
        XCTAssertEqual(try Data(contentsOf: adapterCopy), updated)
        XCTAssertNil(attribute(quarantine, on: adapterCopy))
    }

    func testAdapterCopySitsBesideTheHook() {
        XCTAssertEqual(WidgetConstants.nowPlayingLibrary.deletingLastPathComponent(),
                       WidgetConstants.hookBinary.deletingLastPathComponent())
    }
}
