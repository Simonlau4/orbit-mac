import XCTest
import Darwin
@testable import OrbitCore

final class BuildOutputsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(fm.temporaryDirectory.path, &path) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("orbit-build-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    @discardableResult private func write(_ relative: String, bytes: Int = 5) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: path)
        return path
    }

    func testIdleOldBuildFolderBecomesOneCandidateWithItsContents() throws {
        try write("Project/.next/cache/a.bin", bytes: 7); try write("Project/.next/b.bin", bytes: 3)
        let build = root.appendingPathComponent("Project/.next")
        let item = try XCTUnwrap(BuildOutputs.candidate(build, minimumAgeDays: 7, workingDirectories: ["/"], now: Date().addingTimeInterval(8 * 86400)))
        XCTAssertEqual(item.url.path, build.path); XCTAssertEqual(item.category, .developer)
        XCTAssertEqual(item.bytes, 10); XCTAssertEqual(item.contents?.files, 2)
        XCTAssertNil(BuildOutputs.candidate(build, minimumAgeDays: 7, workingDirectories: []), "changed this week")
        XCTAssertNil(BuildOutputs.candidate(build, minimumAgeDays: 0, workingDirectories: [root.appendingPathComponent("Project/src").path]), "a process works in the project")
        try write("Project/cache/c.bin")
        XCTAssertNil(BuildOutputs.candidate(root.appendingPathComponent("Project/cache"), minimumAgeDays: 0, workingDirectories: []), "not a build folder name")
    }

    func testLinksMoveWithTheFolderButLinkedRootsAndHardLinksStay() throws {
        let outside = try write("outside.bin")
        try write("A/.build/out.bin")
        try fm.createSymbolicLink(at: root.appendingPathComponent("A/.build/link"), withDestinationURL: outside)
        XCTAssertEqual(BuildOutputs.candidate(root.appendingPathComponent("A/.build"), minimumAgeDays: 0, workingDirectories: [])?.contents?.files, 2)
        try fm.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("B/.next"), withDestinationURL: root.appendingPathComponent("A/.build"))
        XCTAssertNil(BuildOutputs.candidate(root.appendingPathComponent("B/.next"), minimumAgeDays: 0, workingDirectories: []))
        try fm.createDirectory(at: root.appendingPathComponent("C/DerivedData"), withIntermediateDirectories: true)
        try fm.linkItem(at: outside, to: root.appendingPathComponent("C/DerivedData/shared.bin"))
        XCTAssertNil(BuildOutputs.candidate(root.appendingPathComponent("C/DerivedData"), minimumAgeDays: 0, workingDirectories: []))
    }

    func testMoveStopsWhenANestedFileChangedAndRestoresTheWholeFolder() async throws {
        let nested = try write("P/.next/cache/a.bin")
        let build = root.appendingPathComponent("P/.next")
        let stale = try XCTUnwrap(BuildOutputs.candidate(build, minimumAgeDays: 0, workingDirectories: []))
        let store = TrashStore(historyURL: root.appendingPathComponent("state/history.json"),
                               allowedRoots: [root.appendingPathComponent("P")], quarantineURL: root.appendingPathComponent("quarantine"))
        // Rewriting in place leaves the folder's own timestamps alone; only the content stamp sees it.
        try Data(repeating: 2, count: 9).write(to: nested)
        XCTAssertEqual(try CleanupPaths.fingerprint(build), stale.fingerprint)
        let refused = try await store.moveToTrash([stale])
        XCTAssertTrue(refused.records.isEmpty); XCTAssertEqual(refused.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: nested.path))
        let fresh = try XCTUnwrap(BuildOutputs.candidate(build, minimumAgeDays: 0, workingDirectories: []))
        let moved = try await store.moveToTrash([fresh])
        XCTAssertEqual(moved.records.count, 1); XCTAssertFalse(fm.fileExists(atPath: build.path))
        try await store.restore(moved.records[0].id)
        XCTAssertEqual(try Data(contentsOf: nested).count, 9)
    }

    func testUnifiedScanAddsOnlyDiscoveredBuildCandidatesAsDeveloperGroups() throws {
        try write("Developer/Site/.next/page.bin", bytes: 11)
        try write("Developer/Site/src/index.ts")
        var issues: [CleanupScanIssue] = []
        let roots = UnifiedCleanupScanner.inventoryRoots(home: root, issues: &issues)
        XCTAssertEqual(UnifiedCleanupScanner.buildOutputRoots(home: root).map(\.path), [root.appendingPathComponent("Developer/Site/.next").path])
        let builds = UnifiedCleanupScanner.buildCandidates(roots, minimumAgeDays: 0)
        XCTAssertEqual(builds.map(\.bytes), [11])
        let merged = UnifiedCleanupScanner.adding(builds, to: CleanupScan(items: [], warnings: [], scannedFiles: 0, isPartial: false))
        XCTAssertEqual(merged.groups.map(\.name), ["Site · .next"])
        XCTAssertEqual(merged.groups.first?.category, .developer)
        XCTAssertEqual(merged.totalBytes, 11)
        XCTAssertTrue(UnifiedCleanupScanner.buildCandidates(roots, minimumAgeDays: 7).isEmpty)
    }

    func testThisProcessWorkingDirectoryIsVisible() throws {
        let directories = try XCTUnwrap(BuildOutputs.workingDirectories())
        XCTAssertTrue(directories.contains(CleanupPaths.normalized(URL(fileURLWithPath: fm.currentDirectoryPath)).path))
    }
}
