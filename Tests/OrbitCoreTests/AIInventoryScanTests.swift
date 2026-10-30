import XCTest
import Darwin
@testable import OrbitCore

final class AIInventoryScanTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_793_097_600)
    private let nested = "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local"
    private var versions: URL { home.appendingPathComponent(nested + "/share/cursor-agent/versions") }
    private var entry: URL { home.appendingPathComponent(nested + "/bin/cursor-agent") }

    override func setUpWithError() throws {
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        home = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-ai-inventory-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: home) }
    @discardableResult private func file(_ suffix: String, bytes: Int, days: Int = 100) throws -> URL {
        let path = home.appendingPathComponent(suffix)
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: path.path)
        return path
    }
    @discardableResult private func version(_ name: String, bytes: Int = 100, days: Int = 100) throws -> URL {
        let directory = versions.appendingPathComponent(name)
        let relative = String(directory.path.dropFirst(home.path.count + 1))
        _ = try file(relative + "/cursor-agent", bytes: bytes, days: days)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: directory.path)
        return directory
    }
    private func link(_ url: URL, to target: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { try fm.removeItem(at: url) }
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
    }
    private func scanner(activity: @escaping AIActivityProvider = { [] }, maximum: Int = 10_000,
                         seconds: TimeInterval = 10) -> AIInventoryScanner {
        AIInventoryScanner(home: home, now: now, maximumFiles: maximum, timeLimit: seconds, activity: activity)
    }

    func testMetadataSeparatesOldAndRecentCacheWithoutReadingProtectedSessionOrModelTrees() async throws {
        let old = try file(".claude/cache/old", bytes: 11)
        let recent = try file(".claude/cache/recent", bytes: 17, days: 1)
        _ = try file(".codex/sessions/session.jsonl", bytes: 300)
        _ = try file(".ollama/models/blobs/model", bytes: 400)
        _ = try file(".claude/projects/conversation.jsonl", bytes: 500)
        let result = await scanner().scan()
        XCTAssertEqual(result.totalBytes, 28)
        XCTAssertEqual(result.candidateBytes, 11)
        XCTAssertEqual(result.retainedBytes, 17)
        XCTAssertEqual(result.items.first { $0.url == old }?.disposition, .candidate)
        XCTAssertEqual(result.items.first { $0.url == recent }?.disposition, .recent)
        XCTAssertEqual(result.metadataFiles.count, 2)
        XCTAssertFalse(result.isPartial)
        XCTAssertTrue(result.metadataFiles.allSatisfy { $0.url.path.contains("/.claude/cache/") })
        XCTAssertTrue(AIInventoryScanner.coveredRoots(home: home).contains(home.appendingPathComponent(".claude/cache")))
    }

    func testRunningToolCacheHasMeasuredOccupancyAndNoCandidate() async throws {
        _ = try file("Library/Caches/com.openai.codex/cache.bin", bytes: 211)
        let result = await scanner(activity: { [.codex] }).scan()
        XCTAssertEqual(result.totalBytes, 211)
        XCTAssertEqual(result.candidateBytes, 0)
        XCTAssertEqual(result.items.first?.disposition, .running)
        XCTAssertFalse(result.isPartial)
    }

    func testNestedVersionsShareCurrentLatestAndKnownEntryProtectionWithDetailedScanner() async throws {
        let oldest = try version("2026.06.01-aabbccd", bytes: 101)
        let current = try version("2026.07.23-e383d2b", bytes: 103)
        let markedLatest = try version("2026.10.14-941492e", bytes: 107)
        let newest = try version("2026.10.16-e3cb207", bytes: 109)
        try link(entry, to: current.appendingPathComponent("cursor-agent"))
        try link(versions.appendingPathComponent("latest"), to: markedLatest)
        let result = await scanner().scan()
        let candidatePaths = Set(result.items.filter { $0.disposition == .candidate }.map { $0.url.path })
        XCTAssertEqual(candidatePaths, [oldest.path])
        for directory in [current, markedLatest, newest] {
            XCTAssertEqual(result.items.first { $0.url.path == directory.path }?.disposition, .currentVersion)
        }
        XCTAssertEqual(result.totalBytes, 420)
        let detailed = await AICleanupScanner(home: home, now: now, activity: { [] }).scan()
        XCTAssertEqual(candidatePaths, Set(detailed.items.filter { $0.kind == .oldVersion }.map { $0.url.path }))
        XCTAssertFalse(result.isPartial)
    }

    func testSameDateBuildsAndGlobalKnownEntryRemainProtected() async throws {
        let global = try version("2026.07.23-e383d2b")
        let older = try version("2026.10.14-941492e")
        let newest = try version("2026.10.16-1111111")
        let sameDate = try version("2026.10.16-eeeeeee")
        try link(entry, to: newest.appendingPathComponent("cursor-agent"))
        try link(home.appendingPathComponent(".local/bin/cursor-agent"), to: global.appendingPathComponent("cursor-agent"))
        let result = await scanner().scan()
        XCTAssertEqual(result.items.filter { $0.disposition == .candidate }.map { $0.url.path }, [older.path])
        for directory in [global, newest, sameDate] {
            XCTAssertEqual(result.items.first { $0.url.path == directory.path }?.disposition, .currentVersion)
        }
    }

    func testUnknownCurrentPointerKeepsMeasuredOldVersions() async throws {
        let older = try version("2026.07.23-e383d2b", bytes: 37)
        _ = try version("2026.10.16-e3cb207", bytes: 43)
        try link(entry, to: home.appendingPathComponent("missing-program"))
        let result = await scanner().scan()
        XCTAssertEqual(result.totalBytes, 80)
        XCTAssertEqual(result.candidateBytes, 0)
        XCTAssertEqual(result.items.first { $0.url.path == older.path }?.disposition, .reviewOnly)
        XCTAssertTrue(result.issues.contains { $0.kind == .io })
    }

    func testRunningOldVersionRemainsVisibleWithBytes() async throws {
        let older = try version("2026.07.23-e383d2b", bytes: 47)
        let newest = try version("2026.10.16-e3cb207", bytes: 53)
        try link(entry, to: newest.appendingPathComponent("cursor-agent"))
        let result = await scanner(activity: { [.cursor] }).scan()
        XCTAssertEqual(result.totalBytes, 100)
        XCTAssertEqual(result.candidateBytes, 0)
        XCTAssertEqual(result.items.first { $0.url.path == older.path }?.disposition, .running)
    }

    func testSymbolicVersionAndCacheEntryDoNotFollowTargetsOrChangeNewestVersion() async throws {
        let older = try version("2026.07.23-e383d2b", bytes: 59)
        let newest = try version("2026.10.16-e3cb207", bytes: 61)
        try link(entry, to: newest.appendingPathComponent("cursor-agent"))
        try link(versions.appendingPathComponent("2027.01.01-deadbee"), to: older)
        let outside = try file("outside/secret", bytes: 999)
        try link(home.appendingPathComponent(".claude/cache/linked"), to: outside)
        let result = await scanner().scan()
        XCTAssertEqual(result.totalBytes, 120)
        XCTAssertEqual(result.items.first { $0.url.path == newest.path }?.disposition, .currentVersion)
        XCTAssertEqual(result.items.filter { $0.disposition == .candidate }.map { $0.url.path }, [older.path])
        XCTAssertFalse(result.metadataFiles.contains { $0.url == outside })
    }

    func testSymbolicAncestorIsReportedWithoutReadingOutsideRoot() async throws {
        _ = try file("outside/codex/data", bytes: 877)
        try link(home.appendingPathComponent(".cache"), to: home.appendingPathComponent("outside"))
        let result = await scanner().scan()
        XCTAssertEqual(result.totalBytes, 0)
        XCTAssertEqual(result.candidateBytes, 0)
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.roots.contains { $0.url.path.hasSuffix("/.cache/codex") && $0.state == .unavailable })
    }

    func testCacheCaseAliasCountsPhysicalDataOnceWithoutSkippingOnCaseSensitiveVolume() async throws {
        let lower = try file(".claude/cache/lower", bytes: 67)
        let upperRoot = home.appendingPathComponent(".claude/Cache")
        var lowerInfo = stat(), upperInfo = stat()
        XCTAssertEqual(lstat(lower.deletingLastPathComponent().path, &lowerInfo), 0)
        if lstat(upperRoot.path, &upperInfo) != 0 { _ = try file(".claude/Cache/upper", bytes: 71) }
        let aliased = lstat(upperRoot.path, &upperInfo) == 0 && lowerInfo.st_ino == upperInfo.st_ino && lowerInfo.st_dev == upperInfo.st_dev
        let result = await scanner().scan()
        XCTAssertEqual(result.totalBytes, aliased ? 67 : 138)
        if aliased { XCTAssertTrue(result.roots.contains { $0.url.path == upperRoot.path && $0.state == .alias }) }
        else { XCTAssertTrue(result.items.contains { $0.rootURL.path == upperRoot.path && $0.disposition == .reviewOnly }) }
        XCTAssertEqual(Set(result.metadataFiles.map(\.identity)).count, result.metadataFiles.count)
    }

    func testHardLinksAcrossCacheRootsCountOnceAndAreNotCandidates() async throws {
        let first = try file(".claude/cache/first", bytes: 73)
        let second = home.appendingPathComponent(".claude/debug/second")
        try fm.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.linkItem(at: first, to: second)
        let result = await scanner().scan()
        XCTAssertEqual(result.totalBytes, 73)
        XCTAssertEqual(result.candidateBytes, 0)
        XCTAssertEqual(result.metadataFiles.count, 1)
        XCTAssertTrue(result.items.allSatisfy { $0.disposition == .reviewOnly })
    }

    func testPermissionFailurePreservesPOSIXCodeAndUnknownOccupancy() async throws {
        let file = try file(".cache/codex/denied", bytes: 79)
        let directory = file.deletingLastPathComponent()
        XCTAssertNotEqual(getuid(), 0, "This fixture requires the ordinary user context used by Orbit")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let result = await scanner().scan()
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.issues.contains { $0.kind == .permission && $0.errorDomain == NSPOSIXErrorDomain && $0.errorCode == Int(EACCES) })
        XCTAssertTrue(result.items.contains { $0.disposition == .unavailable && $0.isPartial })
        XCTAssertEqual(result.totalBytes, 0)
    }

    func testBudgetAndCancellationRemainExplicitAndCoveredRootsRemainExcluded() async throws {
        for i in 0..<20 { _ = try file(".claude/cache/\(i)", bytes: 3) }
        let limited = await scanner(maximum: 4).scan()
        XCTAssertTrue(limited.isPartial)
        XCTAssertTrue(limited.issues.contains { $0.kind == .limit })
        XCTAssertLessThanOrEqual(limited.visitedEntries, 4)
        XCTAssertTrue(limited.items.allSatisfy { $0.disposition != .candidate })
        XCTAssertTrue(AIInventoryScanner.coveredRoots(home: home).contains(home.appendingPathComponent(".claude/cache")))
        let cancelledScanner = scanner()
        let task = Task { await cancelledScanner.scan() }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.isPartial)
        XCTAssertTrue(cancelled.issues.contains { $0.kind == .cancelled })
    }

    func testBudgetAfterCompletedItemsKeepsTheRootPartialAndCountsOnlyMeasuredFiles() async throws {
        for i in 0..<3 { _ = try file(".claude/cache/\(i)", bytes: 3) }
        let result = await scanner(maximum: 5).scan()
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.totalBytes, 6)
        XCTAssertEqual(result.candidateBytes, 6)
        XCTAssertTrue(result.roots.contains { $0.url.path.hasSuffix("/.claude/cache") && $0.state == .partial })
        XCTAssertEqual(result.scannedFiles, 2)
        XCTAssertEqual(result.visitedEntries, 5)
    }

    func testUnreadableChildReportsTheActualFailedPathAndPartialRoot() async throws {
        let blockedFile = try file(".claude/cache/blocked/data", bytes: 89)
        let directory = blockedFile.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let result = await scanner().scan()
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.issues.contains { $0.kind == .permission && $0.path == directory.path })
        XCTAssertTrue(result.items.contains { $0.url.path == directory.path && $0.isPartial && $0.disposition == .reviewOnly })
        XCTAssertTrue(result.roots.contains { $0.url.path.hasSuffix("/.claude/cache") && $0.state == .partial })
    }

    func testProtectedNamesInsideCacheAreNotTraversedAndCannotBecomeCandidates() async throws {
        _ = try file(".claude/cache/skills/secret", bytes: 123)
        _ = try file(".claude/cache/old", bytes: 83)
        let result = await scanner().scan()
        XCTAssertEqual(result.totalBytes, 83)
        XCTAssertEqual(result.candidateBytes, 83)
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.items.contains { $0.url.lastPathComponent == "skills" && $0.disposition == .reviewOnly && $0.isPartial })
        XCTAssertFalse(result.metadataFiles.contains { $0.url.path.contains("/skills/") })
    }

    func testSkillsInsideAStagedApplicationDoNotMarkAnUpdateCacheAsUserData() async throws {
        _ = try file("Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation/x/ChatGPT.app/Contents/Resources/skills/a.md", bytes: 40)
        _ = try file(".claude/cache/skills/secret", bytes: 7)
        let result = await scanner().scan()
        let update = try XCTUnwrap(result.items.first { $0.url.lastPathComponent == "org.sparkle-project.Sparkle" })
        XCTAssertFalse(update.isPartial); XCTAssertEqual(update.bytes, 40)
        XCTAssertFalse(update.reason.contains("记忆"))
        XCTAssertTrue(result.items.contains { $0.url.lastPathComponent == "skills" && $0.disposition == .reviewOnly && $0.isPartial })
    }
}
