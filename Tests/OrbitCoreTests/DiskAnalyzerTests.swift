import XCTest
@testable import OrbitCore

final class DiskAnalyzerTests: XCTestCase {
    func testHiddenScopeAndDirectoryEntriesSupportDrillDown() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orbit-hidden-" + UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 1, count: 30).write(to: root.appendingPathComponent(".git/objects.bin"))
        try Data(repeating: 1, count: 20).write(to: root.appendingPathComponent("plain.bin"))
        let normal = await DiskAnalyzer().scan(root)
        XCTAssertEqual(normal.totalBytes, 20)
        XCTAssertTrue(normal.entries.first { $0.name == "empty" }?.isDirectory == true)
        let hidden = await DiskAnalyzer().scan(root, includeHidden: true)
        XCTAssertEqual(hidden.totalBytes, 50)
        let directory = try XCTUnwrap(hidden.entries.first { $0.name == ".git" })
        XCTAssertTrue(directory.isDirectory)
        let nested = await DiskAnalyzer().scan(directory.url, includeHidden: true)
        XCTAssertEqual(nested.entries.map(\.name), ["objects.bin"])
        XCTAssertEqual(nested.totalBytes, 30)
    }
    func testGroupsLogicalSizesAndSkipsHiddenFilesAndSymlinks() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orbit-disk-" + UUID().uuidString)
        let root = base.appendingPathComponent("scope")
        try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(repeating: 1, count: 400).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 1, count: 700).write(to: root.appendingPathComponent("nested/b.bin"))
        try Data(repeating: 1, count: 900).write(to: root.appendingPathComponent(".hidden"))
        let outside = base.appendingPathComponent("outside.bin")
        try Data(repeating: 1, count: 3000).write(to: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked.bin"), withDestinationURL: outside)
        let report = await DiskAnalyzer().scan(root)
        XCTAssertEqual(report.totalBytes, 1100)
        XCTAssertEqual(report.scannedFiles, 2)
        XCTAssertEqual(report.entries.map(\.name), ["nested", "a.bin"])
        XCTAssertFalse(report.isPartial)
        XCTAssertTrue(report.largeFiles.isEmpty)
    }

    func testBudgetDoesNotClaimCompleteCoverage() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orbit-disk-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for index in 0..<3 { try Data([1]).write(to: root.appendingPathComponent("\(index).bin")) }
        let report = await DiskAnalyzer().scan(root, fileLimit: 1)
        XCTAssertEqual(report.scannedFiles, 1)
        XCTAssertTrue(report.isPartial)
        XCTAssertFalse(report.warnings.isEmpty)
    }
}
