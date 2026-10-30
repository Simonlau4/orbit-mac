import XCTest
import Darwin
@testable import OrbitCore

final class UnifiedCleanupTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(fm.temporaryDirectory.path, &path) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("orbit-unified-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func file(_ relative: String, bytes: Int = 19) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: path)
        return path
    }

    func testReservedAIRootCannotBecomeOrdinaryCandidateWhenAIIsUnavailable() async throws {
        let cache = root.appendingPathComponent("Caches")
        let ai = cache.appendingPathComponent("Claude")
        _ = try file("Caches/Claude/large.bin")
        let ordinary = try file("Caches/closed/ordinary.bin", bytes: 7)
        let policy = CleanupPolicy(roots: [CleanupRoot(url: cache, category: .appCache, minimumAgeDays: 0)], excludedRoots: [ai])
        let scan = await CleanupScanner(policy: policy).scan()
        XCTAssertEqual(scan.items.map(\.url), [ordinary])
        XCTAssertEqual(scan.scannedBytes, 7)
        XCTAssertFalse(scan.metadataFiles.contains { $0.url.path.hasPrefix(ai.path + "/") })
    }

    func testSameFileAcrossOrdinaryAndExtendedRootsIsCountedOnce() async throws {
        let file = try file("cache/data.bin")
        let cache = file.deletingLastPathComponent()
        let ordinary = await CleanupScanner(policy: CleanupPolicy(roots: [CleanupRoot(url: cache, category: .appCache, minimumAgeDays: 0)])).scan()
        let extended = await ExtendedCleanupScanner(policy: ExtendedCleanupPolicy(systemRoots: [ExtendedCleanupRoot(url: cache, title: "fixture")], trashRoots: [])).scan()
        let unified = UnifiedCleanupScan(ordinary: ordinary, ai: AIInventoryScan(), extended: extended)
        XCTAssertEqual(ordinary.scannedBytes, 19)
        XCTAssertEqual(extended.systemBytes, 19)
        XCTAssertEqual(unified.countedBytes, 19)
        XCTAssertEqual(unified.files.count, 1)
        XCTAssertEqual(unified.entries.first { $0.section == .applications }?.countedBytes, 0)
        XCTAssertEqual(unified.entries.first { $0.section == .system }?.countedBytes, 19)
        XCTAssertEqual(unified.entries.compactMap(\.countedBytes).reduce(0, +), unified.countedBytes)
    }

    func testUnknownSystemRootKeepsUnknownSizeAndReadableEmptyTrashIsZero() async throws {
        let trash = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let extended = await ExtendedCleanupScanner(policy: ExtendedCleanupPolicy(systemRoots: [ExtendedCleanupRoot(url: root.appendingPathComponent("missing"), title: "missing")], trashRoots: [trash])).scan()
        let ordinary = CleanupScan(items: [], warnings: [], scannedFiles: 0, isPartial: false)
        let scan = UnifiedCleanupScan(ordinary: ordinary, ai: AIInventoryScan(), extended: extended)
        XCTAssertNil(scan.entries.first { $0.section == .system }?.bytes)
        XCTAssertEqual(scan.entries.first { $0.section == .system }?.detail, "目录不存在")
        XCTAssertFalse(scan.isPartial)
        XCTAssertTrue(scan.entries.allSatisfy { $0.handling != .ordinary })
    }

    func testCommunicationClassificationAndUnknownSharedDataRemainSeparate() async throws {
        _ = try file("Caches/LarkShell/data.bin", bytes: 23)
        let ordinary = await CleanupScanner(policy: CleanupPolicy(roots: [CleanupRoot(url: root.appendingPathComponent("Caches"), category: .appCache, minimumAgeDays: 0)])).scan(runningBundleIDs: ["com.electron.lark"])
        let extended = await ExtendedCleanupScanner(policy: ExtendedCleanupPolicy(systemRoots: [], trashRoots: [])).scan()
        let scan = UnifiedCleanupScan(ordinary: ordinary, ai: AIInventoryScan(), extended: extended)
        XCTAssertEqual(scan.bytes(in: .communication), 23)
        XCTAssertEqual(scan.ordinary.totalBytes, 0)
        XCTAssertEqual(scan.entries.first { $0.section == .communication }?.handling, .retained)
    }

    func testReadProbeDistinguishesMissingFromReadableUsingPhysicalPath() async throws {
        let entries = await ReadAccessProbe().check([ReadAccessTarget(title: "fixture", url: root), ReadAccessTarget(title: "missing", url: root.appendingPathComponent("missing"))])
        XCTAssertEqual(entries.map(\.status), [.readable, .missing])
        XCTAssertEqual(entries.last?.issue?.underlyingPOSIXCode, Int(ENOENT))
    }

    func testReadProbeReturnsRealPermissionDenial() async throws {
        guard getuid() != 0 else { throw XCTSkip("Permission fixture requires an unprivileged user") }
        let denied = root.appendingPathComponent("denied")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let result = await ReadAccessProbe().check([ReadAccessTarget(title: "denied", url: denied)])
        XCTAssertEqual(result.first?.status, .denied)
        XCTAssertEqual(result.first?.issue?.kind, .permission)
        XCTAssertNotNil(result.first?.issue?.underlyingPOSIXCode)
    }

    func testReadProbeDoesNotFollowAncestorLinks() async throws {
        let folder = root.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        let result = await ReadAccessProbe().check([ReadAccessTarget(title: "link", url: link)])
        XCTAssertEqual(result.first?.status, .unavailable)
        XCTAssertEqual(result.first?.issue?.underlyingPOSIXCode, Int(ELOOP))
    }

    func testKnownCacheLeavesAreCoveredAndUnknownOwnerCannotEnterTrashStore() async throws {
        let unknown = try file("Library/Application Support/MysteryApp/GraphiteDawnCache/data.bin")
        let cursor = try file("Library/Application Support/Cursor/CachedData/data.bin")
        let chrome = try file("Library/Application Support/Google/Chrome/component_crx_cache/data.bin")
        let gpu = try file("Library/Application Support/Google/Chrome/Profile 1/GPUCache/data.bin")
        let policy = CleanupPolicy.production(home: root, includeRecentCaches: true, installedApplications: ["com.todesktop.230313mzl4w4u92": ["Cursor"]])
        let result = await CleanupScanner(policy: policy).scan()
        XCTAssertTrue(Set(result.items.map(\.url)).isSuperset(of: [cursor, chrome, gpu]))
        XCTAssertFalse(result.items.contains { $0.url == unknown })
        XCTAssertTrue(result.retained.contains { $0.reason == .unknownOwner && $0.rootURL == unknown.deletingLastPathComponent() && $0.bytes == 19 })
        XCTAssertFalse(policy.writableRoots.contains { unknown.path.hasPrefix($0.url.path + "/") })
    }

    func testWorkspaceDiscoveryFindsOnlyExplicitBuildLeavesAtBoundedDepth() throws {
        let next = try file("Documents/Codex/2026-10-09/task-2/Example/.next/out.bin")
        let build = try file(".codex/worktrees/session/Example/.build/out.bin")
        _ = try file("Documents/Codex/2026-10-09/task-2/Example/node_modules/private.bin")
        var issues: [CleanupScanIssue] = []
        let roots = UnifiedCleanupScanner.inventoryRoots(home: root, issues: &issues)
        XCTAssertTrue(roots.contains { $0.url == next.deletingLastPathComponent() })
        XCTAssertTrue(roots.contains { $0.url == build.deletingLastPathComponent() })
        XCTAssertFalse(roots.contains { $0.url.path.contains("node_modules") })
        XCTAssertTrue(issues.isEmpty)
    }

    func testNegativeDeviceIdentityMatchesOtherInventoryScanners() async throws {
        let url = try file("data.bin")
        let ordinaryFile = CleanupScannedFile(url: url, rootURL: root, category: .appCache, bytes: 19, device: -1, inode: 7, retainedReason: nil)
        let ordinary = CleanupScan(items: [], warnings: [], scannedFiles: 1, isPartial: false, scannedBytes: 19, metadataFiles: [ordinaryFile])
        let aiFile = AIInventoryFile(url: url, itemID: "fixture", device: UInt64.max, inode: 7, bytes: 19, allocatedBytes: 4096)
        let ai = AIInventoryScan(metadataFiles: [aiFile])
        let extended = await ExtendedCleanupScanner(policy: ExtendedCleanupPolicy(systemRoots: [], trashRoots: [])).scan()
        let scan = UnifiedCleanupScan(ordinary: ordinary, ai: ai, extended: extended)
        XCTAssertEqual(scan.countedBytes, 19)
        XCTAssertEqual(scan.files.count, 1)
    }

    func testFrameworkLinksAndExcludedFilesDoNotHideRealSiblingDirectories() async throws {
        let cache = root.appendingPathComponent("Caches")
        let outside = try file("outside/sentinel.bin", bytes: 997)
        var expected: Set<URL> = []
        for index in 0..<8 {
            let version = cache.appendingPathComponent("Framework\(index).framework/Versions")
            try fm.createDirectory(at: version, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: version.appendingPathComponent("Current"), withDestinationURL: version.appendingPathComponent("A"))
            let file = try file("Caches/Framework\(index).framework/Versions/A/Resources/payload.bin", bytes: 31)
            expected.insert(file)
        }
        _ = try file("Caches/excluded.lock", bytes: 101)
        let sibling = try file("Caches/real-sibling/payload.bin", bytes: 17)
        expected.insert(sibling)
        try fm.createSymbolicLink(at: cache.appendingPathComponent("outside-link"), withDestinationURL: outside.deletingLastPathComponent())
        let policy = CleanupPolicy(roots: [CleanupRoot(url: cache, category: .appCache, minimumAgeDays: 0)])
        let scan = await CleanupScanner(policy: policy).scan()
        XCTAssertEqual(Set(scan.items.map(\.url)), expected)
        XCTAssertEqual(scan.scannedBytes, 8 * 31 + 17)
        XCTAssertFalse(scan.metadataFiles.contains { $0.url.path.contains("outside-link") || $0.url == outside })
        let prepared = try CleanupItem.prepare(at: cache)
        XCTAssertEqual(prepared.bytes, 8 * 31 + 17 + 101)
    }

    func testProtectedDatabaseAndMediaContributeOccupancyWithoutBecomingCandidates() async throws {
        let ordinary = try file("Caches/normal/data.bin", bytes: 19)
        let database = try file("Caches/closed/state.sqlite", bytes: 31)
        let wal = try file("Caches/closed/state.sqlite-wal", bytes: 23)
        let shm = try file("Caches/closed/state.db-shm", bytes: 5)
        let media = try file("Caches/closed/Media/resource.bin", bytes: 17)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: database.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path) }
        let policy = CleanupPolicy(roots: [CleanupRoot(url: root.appendingPathComponent("Caches"), category: .appCache, minimumAgeDays: 0)])
        let scan = await CleanupScanner(policy: policy).scan()
        XCTAssertEqual(scan.items.map(\.url), [ordinary])
        XCTAssertEqual(scan.scannedBytes, 95)
        XCTAssertEqual(Set(scan.metadataFiles.map(\.url)), [ordinary, database, wal, shm, media])
        XCTAssertEqual(scan.retained.filter { $0.reason == .protectedData }.reduce(0) { $0 + $1.bytes }, 76)
        XCTAssertThrowsError(try CleanupItem.prepare(at: wal))
        XCTAssertThrowsError(try CleanupItem.prepare(at: shm))
    }

    func testCommandUpdateCopiesAreInventoryOnlyAndDoNotExpandOrdinaryWrites() throws {
        let backup = try file(".local/bin/tool.1793094931179066000.old", bytes: 29)
        _ = try file(".local/bin/normal-tool", bytes: 41)
        var issues: [CleanupScanIssue] = []
        let roots = UnifiedCleanupScanner.inventoryRoots(home: root, issues: &issues)
        XCTAssertTrue(roots.contains { $0.url == backup && $0.section == .manual })
        XCTAssertFalse(roots.contains { $0.url.lastPathComponent == "normal-tool" })
        XCTAssertFalse(CleanupPolicy.production(home: root, installedApplications: [:]).writableRoots.contains { backup.path.hasPrefix($0.url.path + "/") })
    }
}
