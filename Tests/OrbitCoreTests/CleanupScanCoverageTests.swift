import XCTest
import Darwin
@testable import OrbitCore

final class CleanupScanCoverageTests: XCTestCase {
    private var fixture: URL!
    private var home: URL { fixture.appendingPathComponent("home") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(fm.temporaryDirectory.path, &bytes) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        fixture = URL(fileURLWithPath: String(cString: bytes)).appendingPathComponent("orbit-scan-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let fixture { try fm.removeItem(at: fixture) } }

    @discardableResult private func file(_ path: String, text: String = "payload", age: Double = 40) throws -> URL {
        let url = home.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age * 86400)], ofItemAtPath: url.path)
        return url
    }
    private func policy(recent: Bool = false, categories: Set<CleanupCategory>? = nil,
                        applications: [String: Set<String>] = [:]) -> CleanupPolicy {
        .production(home: home, includeRecentCaches: recent, categories: categories, installedApplications: applications)
    }

    func testExactContainerLeavesRoundTripAndKeepPersonalData() async throws {
        let base = "Library/Containers/com.example.closed/Data/Library/"
        let cache = try file(base + "Caches/assets/old.bin")
        let log = try file(base + "Logs/old.log")
        let groupCache = try file("Library/Group Containers/TEAM.com.example.shared/Data/Library/Caches/old.bin")
        let groupLog = try file("Library/Group Containers/TEAM.com.example.shared/Library/Logs/old.log")
        let keep = try ["Cookies/Cookies.binarycookies", "Application Support/chat.db", "Caches/session.sqlite",
                        "Caches/session.sqlite-shm", "Caches/Service Worker/cache", "Caches/Attachments/photo", "Caches/Media/video"].map { try file(base + $0) }
        try file(base + "Logs/recent.log", age: 10)
        try file(base + "Caches/recent.bin", age: 1)
        let plan = policy()
        let result = await CleanupScanner(policy: plan).scan()
        XCTAssertEqual(Set(result.items.map(\.url)), Set([cache, log]))
        XCTAssertEqual(result.retained.filter { $0.reason == .unknownOwner }.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(result.retained.filter { $0.reason == .recent }.reduce(0) { $0 + $1.count }, 2)
        let store = TrashStore(historyURL: fixture.appendingPathComponent("journal.json"), allowedRoots: plan.writableRoots.map(\.url),
                               quarantineURL: fixture.appendingPathComponent("quarantine"))
        let batch = try await store.moveToTrash(result.items)
        XCTAssertEqual(batch.records.count, 2); XCTAssertTrue(batch.failures.isEmpty)
        for record in batch.records { try await store.restore(record.id) }
        let rejected = try await store.moveToTrash([CleanupItem.prepare(at: groupCache)])
        XCTAssertTrue(rejected.records.isEmpty); XCTAssertEqual(rejected.failures.count, 1)
        for url in keep + [cache, log, groupCache, groupLog] { XCTAssertTrue(fm.fileExists(atPath: url.path)) }
    }

    func testInstalledAppSupportScopesKeepUnknownProfilesAndDatabases() async throws {
        let cache = try file("Library/Application Support/Known/Cache/blob")
        let code = try file("Library/Application Support/Known/Code Cache/code")
        let gpu = try file("Library/Application Support/Known/GPUCache/blob")
        try file("Library/Application Support/Unknown/Cache/blob")
        try file("Library/Application Support/Known/Service Worker/offline")
        try file("Library/Application Support/Known/Profile/Cookies")
        try file("Library/Application Support/Known/Cache/IndexedDB/private")
        try file("Library/Application Support/Known/Cache/session.db")
        let result = await CleanupScanner(policy: policy(applications: ["com.example.known": ["Known"]])).scan()
        XCTAssertEqual(Set(result.items.map(\.url)), Set([cache, code, gpu]))
        XCTAssertFalse(result.isPartial)
    }

    func testRunningAliasesAndSharedGroupUseTheExecutionProtection() async throws {
        let active = try ["Library/Caches/LarkShell/old", "Library/Containers/com.bytedance.macos.feishu/Data/Library/Caches/old",
                          "Library/Application Support/Claude/Code Cache/old", "Library/Caches/Codex/old",
                          "Library/Caches/com.tencent.xinWeChat/old", "Library/Group Containers/TEAM.com.tencent.xinWeChat/Library/Caches/old"].map { try file($0) }
        let closed = try file("Library/Caches/com.example.closed/old")
        let ids: Set<String> = ["com.electron.lark", "com.anthropic.claudefordesktop", "com.openai.codex", "com.tencent.xinWeChat"]
        let plan = policy(applications: ["com.anthropic.claudefordesktop": ["Claude"]])
        let result = await CleanupScanner(policy: plan).scan(runningBundleIDs: ids)
        XCTAssertEqual(result.items.map(\.url), [closed])
        XCTAssertEqual(result.retained.filter { $0.reason == .runningApplication }.reduce(0) { $0 + $1.count }, active.count)
        let guardAtExecution = CleanupRunningProtection(runningBundleIDs: ids, roots: plan.roots)
        for url in active { XCTAssertTrue(guardAtExecution.protects(url), url.path) }
        XCTAssertFalse(guardAtExecution.protects(closed))
        XCTAssertFalse(CleanupRunningProtection(runningBundleIDs: [], roots: plan.roots).protects(active[0]))
    }

    func testPhysicalIdentityDeduplicatesRetainedHardLinksAcrossRoots() async throws {
        let first = try file("Library/Caches/first/link", text: "physical")
        let other = home.appendingPathComponent("other-cache")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.linkItem(at: first, to: other.appendingPathComponent("link"))
        let closed = try file("Library/Caches/closed/blob", text: "one")
        let roots = [CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: 7),
                     CleanupRoot(url: other, category: .packageCache, minimumAgeDays: 7)]
        let result = await CleanupScanner(policy: CleanupPolicy(roots: roots)).scan()
        XCTAssertEqual(result.items.map(\.url), [closed])
        XCTAssertEqual(result.scannedFiles, 2)
        XCTAssertEqual(result.scannedBytes, 11)
        XCTAssertEqual(result.retained.filter { $0.reason == .hardLink }.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(result.retained.filter { $0.reason == .hardLink }.reduce(0) { $0 + $1.bytes }, 8)
    }

    func testRunningTreeTraversalUsesGlobalBudgetAndNeverBecomesCandidate() async throws {
        for index in 0..<12 { try file("Library/Caches/LarkShell/file-\(index)") }
        let root = CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: 7)
        let result = await CleanupScanner(policy: CleanupPolicy(roots: [root], maximumFiles: 5)).scan(runningBundleIDs: ["com.electron.lark"])
        XCTAssertTrue(result.items.isEmpty); XCTAssertTrue(result.isPartial)
        XCTAssertLessThanOrEqual(result.visitedEntries, 5)
        XCTAssertTrue(result.issues.contains { $0.kind == .limit && $0.path == root.url.appendingPathComponent("LarkShell").path })
        XCTAssertEqual(result.blockedCount, 0)
        let held = result.retained.filter { $0.reason == .runningApplication }.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(held, 0); XCTAssertLessThan(held, 12)
    }

    func testCandidateLimitIsStructuredAndProductionDefaultAllowsTwoHundredThousand() async throws {
        XCTAssertEqual(policy().maximumItems, 200_000)
        for index in 0..<4 { try file("Library/Caches/old-\(index)") }
        let root = CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: 7)
        let result = await CleanupScanner(policy: CleanupPolicy(roots: [root], maximumItems: 1)).scan()
        XCTAssertEqual(result.items.count, 1); XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.issues.first?.kind, .limit)
        XCTAssertTrue(result.issues.first?.message.contains("1 个候选") == true)
    }

    func testRetainedStatisticsCannotConsumeTheCandidatePhaseBudget() async throws {
        for index in 0..<20 { try file("Library/Caches/LarkShell/old-\(index)") }
        let package = try file(".npm/_cacache/blob")
        let roots = [CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: 7),
                     CleanupRoot(url: home.appendingPathComponent(".npm/_cacache"), category: .packageCache, minimumAgeDays: 7)]
        let result = await CleanupScanner(policy: CleanupPolicy(roots: roots, maximumFiles: 4)).scan(runningBundleIDs: ["com.electron.lark"])
        XCTAssertEqual(result.items.map(\.url), [package])
        XCTAssertLessThanOrEqual(result.visitedEntries, 4)
        XCTAssertTrue(result.retained.contains { $0.reason == .runningApplication && $0.isPartial && $0.bytes > 0 })
        XCTAssertTrue(result.issues.contains { $0.kind == .limit && $0.message.contains("占用") })
    }

    func testUnmeasuredRunningRootIsExplicitlyUnknownInsteadOfZero() async throws {
        let active = try file("Library/Caches/LarkShell/old")
        let package = try file(".npm/_cacache/blob")
        let roots = [CleanupRoot(url: active.deletingLastPathComponent(), category: .appCache, minimumAgeDays: 7),
                     CleanupRoot(url: package.deletingLastPathComponent(), category: .packageCache, minimumAgeDays: 7)]
        let result = await CleanupScanner(policy: CleanupPolicy(roots: roots, maximumItems: 1)).scan(runningBundleIDs: ["com.electron.lark"])
        XCTAssertEqual(result.items.map(\.url), [package])
        let unknown = try XCTUnwrap(result.retained.first { $0.reason == .runningApplication })
        XCTAssertEqual(unknown.bytes, 0); XCTAssertEqual(unknown.count, 0); XCTAssertTrue(unknown.isPartial)
    }

    func testDiscoveryPermissionIssueKeepsFoundationAndUnderlyingPOSIX() async throws {
        let directory = home.appendingPathComponent("Library/Containers")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, 0), 0)
        defer { chmod(directory.path, 0o700) }
        var native: NSError?
        do { _ = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil); XCTFail("Expected non-root permission denial") }
        catch { native = error as NSError }
        let result = await CleanupScanner(policy: policy(categories: [.appCache])).scan()
        let issue = try XCTUnwrap(result.issues.first { $0.path == directory.path })
        XCTAssertEqual(issue.kind, .permission)
        XCTAssertEqual(issue.errorDomain, native?.domain); XCTAssertEqual(issue.errorCode, native?.code)
        XCTAssertEqual(issue.underlyingPOSIXCode, Int(EACCES))
        XCTAssertTrue(result.isPartial); XCTAssertGreaterThan(result.blockedCount, 0)
    }

    func testDisabledCategoriesDoNotDiscoverRestrictedAppData() async throws {
        let package = try file(".npm/_cacache/blob")
        let blocked = [home.appendingPathComponent("Library/Containers"), home.appendingPathComponent("Library/Application Support")]
        for directory in blocked {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertEqual(chmod(directory.path, 0), 0)
        }
        defer { for directory in blocked { chmod(directory.path, 0o700) } }
        let result = await CleanupScanner(policy: policy(categories: [.packageCache])).scan()
        XCTAssertEqual(result.items.map(\.url), [package]); XCTAssertTrue(result.issues.isEmpty)
        XCTAssertFalse(result.isPartial)
    }

    func testEnumeratorPermissionIssuePreservesNativeFailure() async throws {
        let valid = try file("Library/Caches/closed/old")
        let directory = home.appendingPathComponent("Library/Caches/denied")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, 0), 0)
        defer { chmod(directory.path, 0o700) }
        let root = CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: 7)
        let result = await CleanupScanner(policy: CleanupPolicy(roots: [root])).scan()
        XCTAssertEqual(result.items.map(\.url), [valid])
        let issue = try XCTUnwrap(result.issues.first { $0.kind == .permission })
        XCTAssertEqual(issue.errorDomain, NSCocoaErrorDomain)
        XCTAssertEqual(issue.underlyingPOSIXCode, Int(EACCES)); XCTAssertTrue(result.isPartial)
    }

    func testCancellationIsStructuredAndNotAnIOFailure() async throws {
        try file("Library/Caches/closed/old")
        let scanner = CleanupScanner(policy: policy())
        let task = Task { await scanner.scan() }; task.cancel()
        let result = await task.value
        XCTAssertTrue(result.items.isEmpty); XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.issues.first?.kind, .cancelled); XCTAssertEqual(result.blockedCount, 0)
    }

    func testSmallRebuildableCachesAndUpdaterProtectionExcludeUVAndNpx() async throws {
        let bun = try file(".bun/install/cache/pkg/blob")
        let corepack = try file(".cache/node/corepack/blob")
        let darwinCorepack = try file("Library/Caches/node/corepack/blob")
        let fonts = try file(".cache/fontconfig/blob")
        let updater = try file("Library/Application Support/Google/GoogleUpdater/crx_cache/update.crx")
        try file(".cache/uv/builds-v0/.tmp-build/blob")
        try file(".cache/uv/archive-v0/blob")
        try file(".npm/_npx/blob")
        try file("project/.build/blob")
        let plan = policy()
        let result = await CleanupScanner(policy: plan).scan(runningBundleIDs: ["com.google.Chrome"])
        XCTAssertEqual(Set(result.items.map(\.url)), Set([bun, corepack, darwinCorepack, fonts]))
        XCTAssertTrue(CleanupRunningProtection(runningBundleIDs: ["com.google.GoogleUpdater"], roots: plan.roots).protects(updater))
        XCTAssertEqual(result.retained.filter { $0.reason == .runningApplication }.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(result.items.filter { $0.category == .packageCache }.count, 3)
    }

    func testInstalledBundleMetadataDiscoversOnlyItsExactCache() async throws {
        let info = home.appendingPathComponent("Applications/Fixture.app/Contents/Info.plist")
        try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.fixture", "CFBundleName": "FixtureElectron"], format: .xml, options: 0)
        try data.write(to: info)
        let cache = try file("Library/Application Support/FixtureElectron/Cache/old")
        try file("Library/Application Support/NotInstalled/Cache/old")
        let result = await CleanupScanner(policy: .production(home: home)).scan()
        XCTAssertEqual(result.items.map(\.url), [cache]); XCTAssertTrue(result.issues.isEmpty)
    }

    func testBrowserSingletonLinksAreOutsideProfileDiscoveryAndDoNotInventIssues() async throws {
        let cache = try file("Library/Application Support/Google/Chrome/Default/Cache/old")
        let browser = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try fm.createSymbolicLink(atPath: browser.appendingPathComponent("SingletonLock").path, withDestinationPath: "/does-not-exist")
        let result = await CleanupScanner(policy: policy()).scan()
        XCTAssertEqual(result.items.map(\.url), [cache])
        XCTAssertTrue(result.issues.isEmpty); XCTAssertEqual(result.blockedCount, 0); XCTAssertFalse(result.isPartial)
    }

    func testIndependentSharedGroupNamesAreInventoryOnlyEvenWhenConsumerRuns() async throws {
        let shared = try file("Library/Group Containers/TEAM.com.vendor.shared/Library/Caches/blob")
        let office = try file("Library/Group Containers/UBF8T346G9.Office/Data/Library/Logs/old.log")
        let plan = policy()
        let result = await CleanupScanner(policy: plan).scan(runningBundleIDs: ["com.vendor.editor", "com.microsoft.Word"])
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.retained.filter { $0.reason == .unknownOwner }.reduce(0) { $0 + $1.count }, 2)
        for url in [shared, office] {
            XCTAssertFalse(plan.writableRoots.contains { url.path.hasPrefix($0.url.path + "/") })
            XCTAssertTrue(plan.roots.contains { $0.inventoryOnly && url.path.hasPrefix($0.url.path + "/") })
        }
    }

    func testNonRunningRetainedSummariesAreLowerBoundsAfterReadFailure() async throws {
        try file("Library/Caches/recent", age: 1)
        let hardlink = try file("Library/Caches/hardlink")
        let outside = home.appendingPathComponent("outside-link")
        try fm.linkItem(at: hardlink, to: outside)
        let denied = home.appendingPathComponent("Library/Caches/denied")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(denied.path, 0), 0); defer { chmod(denied.path, 0o700) }
        let root = CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: 7)
        let result = await CleanupScanner(policy: CleanupPolicy(roots: [root])).scan()
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(try XCTUnwrap(result.retained.first { $0.reason == .recent }).isPartial)
        XCTAssertTrue(try XCTUnwrap(result.retained.first { $0.reason == .hardLink }).isPartial)
    }

    func testTerminationIssuesSurviveTheBoundedReadFailureList() async throws {
        let root = CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: 7)
        let failures = (0..<70).map { CleanupScanIssue(kind: .permission, path: root.url.path + "/denied-\($0)",
            errorDomain: NSCocoaErrorDomain, errorCode: NSFileReadNoPermissionError, underlyingPOSIXCode: Int(EACCES), message: "denied \($0)") }
        let scanner = CleanupScanner(policy: CleanupPolicy(roots: [root], maximumFiles: 0, discoveryIssues: failures))
        let limited = await scanner.scan()
        XCTAssertEqual(limited.blockedCount, 70); XCTAssertEqual(limited.issues.count, 64)
        XCTAssertTrue(limited.issues.contains { $0.kind == .limit }); XCTAssertTrue(limited.isPartial)
        XCTAssertTrue(limited.warnings.contains { $0.contains("上限") })
        let task = Task { await scanner.scan() }; task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.issues.contains { $0.kind == .cancelled })
        XCTAssertLessThanOrEqual(cancelled.issues.count, 64)
    }

    func testDiscoveryRejectsIntermediateLinksBeforeListingContainers() throws {
        try file("outside/Containers/com.example.secret/Data/Library/Caches/blob")
        let link = home.appendingPathComponent("Library")
        try fm.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("outside"))
        var issues: [CleanupScanIssue] = []
        let directory = link.appendingPathComponent("Containers")
        XCTAssertTrue(CleanupScopeDiscovery.children(directory, issues: &issues).isEmpty)
        XCTAssertEqual(issues.first?.path, directory.path)
        XCTAssertTrue(issues.first?.message.contains("符号链接") == true)
        let plan = policy()
        XCTAssertFalse(plan.roots.contains { $0.url.path.contains("com.example.secret") })
        XCTAssertTrue(plan.discoveryIssues.contains { $0.path == directory.path })
    }
}
