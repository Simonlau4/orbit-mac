import XCTest
import Darwin
@testable import OrbitCore

final class ExtendedCleanupScanTests: XCTestCase {
    private let fm = FileManager.default
    private var fixture: URL!

    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["ORBIT_TEST_FIXTURES"] ?? fm.temporaryDirectory.path
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(base, &buffer) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        fixture = URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("orbit-extended-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let fixture { try fm.removeItem(at: fixture) } }

    @discardableResult private func file(_ path: String, count: Int) throws -> URL {
        let url = fixture.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: count).write(to: url)
        return url
    }

    private func policy(systems: [String] = [], trash: [String] = [], maximumEntries: Int = 10_000,
                        maximumTrashItems: Int = 1_000, timeLimit: TimeInterval = 10) -> ExtendedCleanupPolicy {
        ExtendedCleanupPolicy(systemRoots: systems.map { ExtendedCleanupRoot(url: fixture.appendingPathComponent($0), title: $0) },
            trashRoots: trash.map { fixture.appendingPathComponent($0) }, maximumEntries: maximumEntries,
            maximumTrashItems: maximumTrashItems, timeLimit: timeLimit)
    }

    func testSystemAndTrashMetadataStaySeparateAndNeverMoveFiles() async throws {
        let system = try file("system/nested/blob", count: 1_001)
        let app = try file("trash/Old.app/Contents/MacOS/Old", count: 2_003)
        let image = try file("trash/installer.dmg", count: 4_007)
        let result = await ExtendedCleanupScanner(policy: policy(systems: ["system"], trash: ["trash"])).scan()
        XCTAssertEqual(result.systemBytes, 1_001); XCTAssertEqual(result.trashBytes, 6_010)
        XCTAssertEqual(result.items.count, 3); XCTAssertEqual(result.files.count, 3)
        XCTAssertEqual(Set(result.files.map(\.url)), Set([system, app, image]))
        XCTAssertEqual(result.items.first?.handling, .administratorReview)
        XCTAssertTrue(result.items.filter { $0.section == .trash }.allSatisfy { $0.handling == .permanentRemovalReview })
        XCTAssertFalse(result.isPartial); XCTAssertTrue(result.issues.isEmpty)
        for url in [system, app, image] { XCTAssertTrue(fm.fileExists(atPath: url.path)) }
        var metadata = stat(); XCTAssertEqual(lstat(system.path, &metadata), 0)
        let stamp = try XCTUnwrap(result.files.first { $0.url == system })
        XCTAssertEqual(stamp.device, UInt64(bitPattern: Int64(metadata.st_dev)))
        XCTAssertEqual(stamp.inode, UInt64(metadata.st_ino)); XCTAssertEqual(stamp.logicalBytes, 1_001)
        XCTAssertEqual(stamp.allocatedBytes, Int64(metadata.st_blocks) * 512)
    }

    func testReadableEmptyMissingAndDeniedHaveDistinctSizesAndStatus() async throws {
        let empty = fixture.appendingPathComponent("empty")
        let denied = fixture.appendingPathComponent("denied")
        for url in [empty, denied] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let scanner = ExtendedCleanupScanner(policy: policy(systems: ["empty", "absent", "denied"])) { url in
            if url.path == denied.path {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
            }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        let result = await scanner.scan()
        XCTAssertEqual(result.items.map(\.access), [.readable, .missing, .denied])
        XCTAssertEqual(result.items[0].logicalBytes, 0)
        XCTAssertNil(result.items[1].logicalBytes); XCTAssertNil(result.items[2].logicalBytes)
        XCTAssertFalse(result.items[1].isPartial); XCTAssertTrue(result.items[2].isPartial)
        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .permission); XCTAssertEqual(issue.errorDomain, NSCocoaErrorDomain)
        XCTAssertEqual(issue.errorCode, NSFileReadNoPermissionError); XCTAssertEqual(issue.underlyingPOSIXCode, Int(EPERM))
    }

    func testNestedReadFailurePreservesKnownLowerBoundAndRealPath() async throws {
        try file("system/a-known", count: 16)
        try file("system/denied/private", count: 32)
        let denied = fixture.appendingPathComponent("system/denied")
        let scanner = ExtendedCleanupScanner(policy: policy(systems: ["system"])) { url in
            if url.path == denied.path { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        let result = await scanner.scan()
        XCTAssertEqual(result.systemBytes, 16); XCTAssertEqual(result.items.first?.access, .partial)
        XCTAssertTrue(result.isPartial); XCTAssertEqual(result.issues.first?.path, denied.path)
        XCTAssertEqual(result.issues.first?.underlyingPOSIXCode, Int(EACCES))
    }

    func testAncestorSymlinkNeverReadsTarget() async throws {
        let outside = try file("outside/cache/private", count: 256)
        let link = fixture.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: fixture.appendingPathComponent("outside"))
        let result = await ExtendedCleanupScanner(policy: policy(systems: ["linked/cache"])).scan()
        XCTAssertEqual(result.items.first?.access, .unsupported)
        XCTAssertNil(result.items.first?.logicalBytes); XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.visitedEntries, 0); XCTAssertTrue(fm.fileExists(atPath: outside.path))
    }

    func testLeafSymlinkCountsOnlyTheLinkAndNeverTraversesTarget() async throws {
        let outside = try file("outside/private", count: 50_000)
        let inside = try file("system/local", count: 7)
        let link = fixture.appendingPathComponent("system/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        var metadata = stat(); XCTAssertEqual(lstat(link.path, &metadata), 0)
        let result = await ExtendedCleanupScanner(policy: policy(systems: ["system"])).scan()
        XCTAssertEqual(result.systemBytes, 7 + metadata.st_size)
        XCTAssertEqual(result.items.first?.symbolicLinkCount, 1)
        XCTAssertEqual(result.files.map(\.url), [inside]); XCTAssertFalse(result.isPartial)
    }

    func testHardLinksAndOverlappingRootsCountOnePhysicalFile() async throws {
        let first = try file("system/a/blob", count: 256)
        let alias = fixture.appendingPathComponent("system/b-link")
        try fm.linkItem(at: first, to: alias)
        let result = await ExtendedCleanupScanner(policy: policy(systems: ["system", "system/a", "system"])).scan()
        XCTAssertEqual(result.systemBytes, 256); XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.items.first?.hardLinkBytes, 256)
        XCTAssertTrue(try XCTUnwrap(result.files.first).isHardLinked)
        XCTAssertEqual(Array(result.items.dropFirst()).map(\.access), [.duplicate])
        XCTAssertTrue(result.items.allSatisfy { $0.handling == .administratorReview })
    }

    func testEntryBudgetKeepsKnownFilesAndMarksUnvisitedRootsUnknown() async throws {
        try file("first/a", count: 3); try file("first/b", count: 5); try file("second/a", count: 7)
        let result = await ExtendedCleanupScanner(policy: policy(systems: ["first", "second"], maximumEntries: 2)).scan()
        XCTAssertEqual(result.visitedEntries, 2); XCTAssertEqual(result.systemBytes, 3)
        XCTAssertEqual(result.items.map(\.access), [.partial, .partial])
        XCTAssertEqual(result.items[0].logicalBytes, 3); XCTAssertNil(result.items[1].logicalBytes)
        XCTAssertTrue(result.issues.allSatisfy { $0.kind == .limit })
        let rootOnly = await ExtendedCleanupScanner(policy: policy(systems: ["first"], maximumEntries: 1)).scan()
        XCTAssertNil(rootOnly.items.first?.logicalBytes); XCTAssertEqual(rootOnly.items.first?.access, .partial)
    }

    func testTrashTopLevelLimitRetainsExplicitUncountedRemainder() async throws {
        try file("trash/a", count: 7); try file("trash/b", count: 13)
        let result = await ExtendedCleanupScanner(policy: policy(trash: ["trash"], maximumTrashItems: 1)).scan()
        XCTAssertTrue([Int64(7), 13].contains(result.trashBytes)); XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items.first?.access, .readable)
        XCTAssertEqual(result.items.last?.access, .partial); XCTAssertNil(result.items.last?.logicalBytes)
        XCTAssertEqual(result.issues.last?.kind, .limit)
    }

    func testNativeDirectoryDiscoveryStopsBeforeMaterializingAllChildren() async throws {
        for index in 0..<100 { try file("large/item-\(index)", count: 1) }
        let folder = fixture.appendingPathComponent("large")
        let listing = try ExtendedCleanupScanner.boundedDirectoryEntries(folder, maximum: 3,
            deadline: ProcessInfo.processInfo.systemUptime + 5)
        XCTAssertEqual(listing.entries.count, 3); XCTAssertTrue(listing.truncated)
        let scan = await ExtendedCleanupScanner(policy: policy(systems: ["large"], maximumEntries: 3)).scan()
        XCTAssertEqual(scan.visitedEntries, 3); XCTAssertEqual(scan.systemBytes, 2)
        XCTAssertTrue(scan.isPartial); XCTAssertTrue(scan.issues.contains { $0.kind == .limit })
    }

    func testTrashEmptyAndDeniedAreNotBothZero() async throws {
        let trash = fixture.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let empty = await ExtendedCleanupScanner(policy: policy(trash: ["trash"])).scan()
        XCTAssertEqual(empty.items.first?.logicalBytes, 0); XCTAssertEqual(empty.items.first?.access, .readable)
        let denied = await ExtendedCleanupScanner(policy: policy(trash: ["trash"])) { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }.scan()
        XCTAssertNil(denied.items.first?.logicalBytes); XCTAssertEqual(denied.items.first?.access, .denied)
    }

    func testTimeBudgetDoesNotClaimZeroForExistingData() async throws {
        try file("system/blob", count: 99)
        let result = await ExtendedCleanupScanner(policy: policy(systems: ["system"], timeLimit: 0)).scan()
        XCTAssertTrue(result.isPartial); XCTAssertNil(result.items.first?.logicalBytes)
        XCTAssertEqual(result.issues.first?.kind, .limit)
    }

    func testProductionPolicyHasOnlyExplicitSystemRootsAndActualLocalVolumeCandidates() {
        let production = ExtendedCleanupPolicy.production(home: fixture, mountedVolumes: [], userID: 501)
        XCTAssertEqual(Set(production.systemRoots.map { $0.url.path }), Set([
            "/Library/Caches", "/Library/Developer/CoreSimulator/Caches", "/private/var/log",
            "/private/var/db/diagnostics", "/private/var/db/uuidtext"
        ]))
        XCTAssertEqual(production.trashRoots, [fixture.appendingPathComponent(".Trash")])
    }
}
