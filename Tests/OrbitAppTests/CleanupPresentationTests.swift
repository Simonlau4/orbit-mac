import XCTest
import Combine
import Darwin
import OrbitCore
@testable import Orbit

@MainActor
final class CleanupPresentationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &path) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("orbit-ui-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }
    private func file(_ name: String, bytes: Int, category: CleanupCategory = .appCache) throws -> CleanupItem {
        try CleanupItem.prepare(at: write(name, bytes: bytes), category: category)
    }
    private func scan() throws -> CleanupScan {
        let a = try file("browser/Alpha.bin", bytes: 3), b = try file("browser/Beta.bin", bytes: 5)
        let c = try file("build/Gamma.bin", bytes: 7, category: .developer)
        return CleanupScan(items: [a, b, c], warnings: [], scannedFiles: 3, isPartial: false, groups: [
            CleanupGroup(id: "browser", name: "Browser fixtures", category: .appCache, items: [a, b]),
            CleanupGroup(id: "build", name: "Build fixtures", category: .developer, items: [c])
        ])
    }

    func testSelectionTotalsFollowSelectionAndIgnoreUnknownIDs() throws {
        let scan = try scan(), state = AppState()
        state.scan = scan
        XCTAssertEqual(state.selectedBytes, 0)
        state.selection = [scan.items[2].id, "not-in-this-scan", scan.items[0].id]
        XCTAssertEqual(state.selectedBytes, 10)
        XCTAssertEqual(state.selectedItems.map(\.id), [scan.items[0].id, scan.items[2].id])
        state.selection.insert(scan.items[1].id)
        XCTAssertEqual(state.selectedBytes, 15)
        state.selection.remove(scan.items[0].id)
        XCTAssertEqual(state.selectedBytes, 12)
        state.selection = []
        XCTAssertEqual(state.selectedBytes, 0); XCTAssertTrue(state.selectedItems.isEmpty)
    }

    func testNewScanAndInvalidationCannotReuseCachedTotalsOrGroups() throws {
        let state = AppState(), first = try scan()
        let request = try XCTUnwrap(state.beginCleanupScanRequest())
        XCTAssertTrue(state.completeCleanupScanRequest(first, id: request))
        state.selection = Set(first.items.map(\.id))
        XCTAssertEqual(state.selectedBytes, 15)
        let next = try XCTUnwrap(state.beginCleanupScanRequest())
        XCTAssertEqual(state.selectedBytes, 0); XCTAssertTrue(state.cleanupIndex.groupItemIDs.isEmpty)
        let item = try file("new.bin", bytes: 13)
        let second = CleanupScan(items: [item], warnings: [], scannedFiles: 1, isPartial: false)
        XCTAssertTrue(state.completeCleanupScanRequest(second, id: next))
        XCTAssertEqual(state.selection, [item.id])
        XCTAssertNil(state.cleanupIndex.itemsByID[first.items[0].id])
        state.selection = [item.id]; XCTAssertEqual(state.selectedBytes, 13)
        state.invalidateCleanupResults()
        XCTAssertEqual(state.selectedBytes, 0); XCTAssertTrue(state.cleanupIndex.rows.isEmpty)
    }

    func testGroupStateDistinguishesEmptyPartialAndFullSelection() {
        let ids: Set<String> = ["a", "b"]
        XCTAssertEqual(GroupSelectionState(ids: [], selection: ["outside"]), .none)
        XCTAssertEqual(GroupSelectionState(ids: ids, selection: ["outside"]), .none)
        XCTAssertEqual(GroupSelectionState(ids: ids, selection: ["a", "outside"]), .mixed)
        XCTAssertEqual(GroupSelectionState(ids: ids, selection: ["a", "b", "outside"]), .all)
    }

    func testSelectingMixedGroupSelectsAllAndDeselectingPreservesOtherGroups() {
        let ids: Set<String> = ["a", "b"], partial: Set<String> = ["a", "outside"]
        let selected = GroupSelectionState.selecting(true, ids: ids, in: partial)
        XCTAssertEqual(selected, ["a", "b", "outside"])
        XCTAssertEqual(GroupSelectionState(ids: ids, selection: selected), .all)
        XCTAssertEqual(GroupSelectionState.selecting(false, ids: ids, in: selected), ["outside"])
    }

    func testOrdinarySearchMatchesGroupNamePathAndCategory() throws {
        let scan = try scan(), index = CleanupResultsIndex(scan)
        let byName = index.search("BROWSER", category: nil)
        XCTAssertEqual(byName.groups.map(\.id), ["browser"])
        XCTAssertEqual(byName.itemsByGroup["browser"]?.count, 2)
        let byPath = index.search("bEtA.BiN", category: .appCache)
        XCTAssertEqual(byPath.itemsByGroup["browser"]?.map(\.id), [scan.items[1].id])
        // A group checkbox still addresses the whole group, including rows outside the search.
        XCTAssertEqual(byPath.selectableIDs, Set(scan.items.prefix(2).map(\.id)))
        XCTAssertTrue(index.search("Beta.bin", category: .developer).groups.isEmpty)
    }

    func testOrdinarySearchEmptyResultAndClearingQuery() throws {
        let index = CleanupResultsIndex(try scan())
        XCTAssertTrue(index.search("does-not-match", category: nil).groups.isEmpty)
        let cleared = index.search("", category: nil)
        XCTAssertEqual(cleared.groups.count, 2); XCTAssertEqual(cleared.selectableIDs.count, 3)
    }

    func testOrdinaryDisplayLimitPreservesFullGroupSelection() throws {
        let items = try (0..<305).map { try file("cache-\($0).bin", bytes: 1) }
        let scan = CleanupScan(items: items, warnings: [], scannedFiles: items.count, isPartial: false)
        let index = CleanupResultsIndex(scan), result = index.search("", category: nil)
        XCTAssertEqual(result.itemsByGroup[CleanupCategory.appCache.rawValue]?.count, 300)
        XCTAssertEqual(result.selectableIDs.count, 305)
        XCTAssertEqual(index.selectedBytes(result.selectableIDs), 305)
        XCTAssertEqual(index.search("cache-304", category: nil).itemsByGroup[CleanupCategory.appCache.rawValue]?.count, 1)
    }

    func testScanPreselectsOnlyRecommendedTier() throws {
        let state = AppState(), result = try scan()
        let request = try XCTUnwrap(state.beginCleanupScanRequest())
        XCTAssertTrue(state.completeCleanupScanRequest(result, id: request))
        XCTAssertEqual(state.selection, Set(result.items.prefix(2).map(\.id)))
        XCTAssertEqual(state.selectedBytes, 8)
        let tiers = state.cleanupIndex.tiers("")
        XCTAssertEqual(tiers.map(\.tier), [.recommended, .decide])
        XCTAssertEqual(tiers.map { $0.rows.map(\.id) }, [["browser"], ["build"]])
        XCTAssertEqual(tiers[1].ids, [result.items[2].id])
    }

    func testTierSearchMatchesTitleNameAndPath() throws {
        let index = CleanupResultsIndex(try scan())
        XCTAssertEqual(index.tiers("BUILD FIX").map(\.tier), [.decide])
        XCTAssertEqual(index.tiers("xcode").first?.rows.map(\.id), ["build"])
        XCTAssertEqual(index.tiers(root.lastPathComponent).flatMap(\.rows).count, 2)
        XCTAssertTrue(index.tiers("does-not-match").isEmpty)
    }

    func testSmallRowsFoldOnlyWithoutQuery() throws {
        func groups(_ count: Int) throws -> CleanupScan {
            let groups = try (0..<count).map { CleanupGroup(id: "g\($0)", name: "g\($0)", category: .appCache, items: [try file("g\($0)/f.bin", bytes: 10 - $0)]) }
            return CleanupScan(items: groups.flatMap(\.items), warnings: [], scannedFiles: count, isPartial: false, groups: groups)
        }
        let folded = try XCTUnwrap(CleanupResultsIndex(try groups(8)).tiers("").first)
        XCTAssertEqual(folded.rows.map(\.id), ["g0", "g1", "g2", "g3", "g4"])
        XCTAssertEqual(folded.folded.map(\.id), ["g5", "g6", "g7"])
        XCTAssertEqual(folded.ids.count, 8)
        XCTAssertTrue(try XCTUnwrap(CleanupResultsIndex(try groups(8)).tiers("g").first).folded.isEmpty)
        XCTAssertEqual(try XCTUnwrap(CleanupResultsIndex(try groups(6)).tiers("").first).rows.count, 6)
    }

    func testAdviceUsesPlainNamesForKnownLocationsAndApps() {
        let apps = ["com.google.GeminiMacOS": "Gemini", "com.todesktop.230313mzl4w4u92": "Cursor"]
        func title(_ name: String, _ category: CleanupCategory, _ path: String) -> String {
            CleanupAdvisor.advice(name: name, category: category, location: URL(fileURLWithPath: path), appName: { apps[$0] }).title
        }
        XCTAssertEqual(title("npm", .packageCache, "/u/.npm/_cacache/content-v2"), "npm 下载缓存")
        XCTAssertEqual(title("com.apple.mediaanalysisd", .appCache, "/u/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches"), "照片与视频分析缓存")
        XCTAssertEqual(title("com.google.GeminiMacOS", .appCache, "/u/Library/Caches/com.google.GeminiMacOS/Updates/1.2"), "Gemini 旧更新包")
        XCTAssertEqual(title("com.todesktop.230313mzl4w4u92.ShipIt", .appCache, "/u/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"), "Cursor 旧更新包")
        XCTAssertEqual(title("@deepseek-aidsh-desktop-updater", .appCache, "/u/Library/Caches/@deepseek-aidsh-desktop-updater"), "deepseek-aidsh-desktop 旧更新包")
        XCTAssertEqual(title("com.google.GeminiMacOS.launcher", .appCache, "/u/Library/Caches/com.google.GeminiMacOS.launcher/Logs"), "Gemini 旧日志")
        XCTAssertEqual(title("com.apple.helpd", .appCache, "/u/Library/Caches/com.apple.helpd/fsCachedData"), "macOS helpd 网络缓存")
        XCTAssertEqual(title("Google Chrome · Default", .browserCache, "/u/Chrome/Default/Cache"), "Google Chrome 网页缓存")
        XCTAssertEqual(title("Google Chrome · Profile 1", .browserCache, "/u/Chrome/Profile 1/Cache"), "Google Chrome 网页缓存（Profile 1）")
        XCTAssertEqual(title("Caches · 散落文件", .appCache, "/u/Library/Caches"), "缓存文件夹里的零散文件")
        XCTAssertEqual(title("DoubaoWork", .appCache, "/u/Library/Caches/DoubaoWork/Default/Cache"), "DoubaoWork 缓存")
        XCTAssertEqual(title("下载的安装包", .installers, "/u/Downloads"), "下载文件夹里的旧安装包")
        XCTAssertEqual(title("SampleWeb · .next", .developer, "/u/Developer/SampleWeb/.next"), "SampleWeb 项目的 Next.js 构建产物")
        XCTAssertEqual(title("SampleApp · .build", .developer, "/u/Developer/SampleApp/.build"), "SampleApp 项目的 Swift 构建产物")
        XCTAssertEqual(title("MyApp-abc", .developer, "/u/Library/Developer/Xcode/DerivedData/MyApp-abc"), "Xcode 构建缓存")
        XCTAssertTrue(CleanupAdvisor.advice(name: "com.todesktop.230313mzl4w4u92.ShipIt", category: .appCache, location: URL(fileURLWithPath: "/u/Library/Caches/x.ShipIt"), appName: { apps[$0] }).decide)
        XCTAssertFalse(CleanupAdvisor.advice(name: "npm", category: .packageCache, location: URL(fileURLWithPath: "/u/.npm/_cacache"), appName: { apps[$0] }).decide)
        XCTAssertEqual(CleanupTier(.installers), .decide); XCTAssertEqual(CleanupTier(.developer), .decide)
        XCTAssertEqual(CleanupTier(.logs), .recommended); XCTAssertEqual(CleanupTier(.packageCache), .recommended)
    }

    func testUpdateCachesAndBuildFoldersWaitInDecideTierUnselected() throws {
        let cache = try file("cache/a.bin", bytes: 2), update = try file("Caches/com.example.ShipIt/update.zip", bytes: 4)
        let folder = root.appendingPathComponent("Site/.next")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 6).write(to: folder.appendingPathComponent("page.bin"))
        let build = try XCTUnwrap(BuildOutputs.candidate(folder, minimumAgeDays: 0, workingDirectories: []))
        let scan = CleanupScan(items: [cache, update, build], warnings: [], scannedFiles: 3, isPartial: false, groups: [
            CleanupGroup(id: "cache", name: "cache", category: .appCache, items: [cache]),
            CleanupGroup(id: "update", name: "com.example.ShipIt", category: .appCache, items: [update]),
            CleanupGroup(id: "build", name: "Site · .next", category: .developer, items: [build])])
        let state = AppState(), request = try XCTUnwrap(state.beginCleanupScanRequest())
        XCTAssertTrue(state.completeCleanupScanRequest(scan, id: request))
        XCTAssertEqual(state.selection, [cache.id])
        let decide = try XCTUnwrap(state.cleanupIndex.tiers("").first { $0.tier == .decide })
        XCTAssertEqual(Set(decide.rows.map(\.id)), ["update", "build"])
        XCTAssertEqual(decide.rows.first { $0.id == "build" }?.location.path, folder.path)
        XCTAssertTrue(decide.rows.first { $0.id == "build" }?.advice.detail.hasPrefix(shortPath(folder.deletingLastPathComponent())) == true)
    }

    func testRowLocationIsTheGroupFolderAndRunningAppsAreNamed() throws {
        let a = try file("cache/one/a.bin", bytes: 1), b = try file("cache/two/deep/b.bin", bytes: 1)
        let running = [
            CleanupRetainedSummary(reason: .runningApplication, category: .appCache, rootURL: root.appendingPathComponent("x"), ownerBundleID: "com.example.chat", count: 1, bytes: 5),
            CleanupRetainedSummary(reason: .runningApplication, category: .logs, rootURL: root.appendingPathComponent("y"), ownerBundleID: "com.example.chat", count: 1, bytes: 9),
            CleanupRetainedSummary(reason: .runningApplication, category: .appCache, rootURL: root.appendingPathComponent("Browser"), count: 1, bytes: 1)
        ]
        let scan = CleanupScan(items: [a, b], warnings: [], scannedFiles: 2, isPartial: false,
            groups: [CleanupGroup(id: "g", name: "g", category: .appCache, items: [a, b])], retained: running)
        let index = CleanupResultsIndex(scan, appName: { $0 == "com.example.chat" ? "Chat" : nil })
        XCTAssertEqual(index.rows.first?.location.path, root.appendingPathComponent("cache").path)
        XCTAssertEqual(index.runningApps, ["Chat", "Browser"])
        XCTAssertEqual(index.runningBytes, 15)
        XCTAssertEqual(commonFolder([a.url]).path, a.url.deletingLastPathComponent().path)
    }

    func testZeroBytesUsesNumericFormatting() {
        XCTAssertEqual(prettyBytes(0), "0 KB")
        XCTAssertFalse(prettyBytes(512).localizedCaseInsensitiveContains("byte"))
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        XCTAssertEqual(prettyBytes(1_234_567), formatter.string(fromByteCount: 1_234_567))
    }

    func testMonitoringChangesDoNotPublishAppStateChanges() {
        let state = AppState()
        var appChanges = 0, monitorChanges = 0
        let appSubscription = state.objectWillChange.sink { appChanges += 1 }
        let monitorSubscription = state.monitoring.objectWillChange.sink { monitorChanges += 1 }
        state.monitoring.snapshot = nil; state.monitoring.samples = []; state.monitoring.thermalSnapshot = nil
        XCTAssertEqual(appChanges, 0); XCTAssertEqual(monitorChanges, 3)
        withExtendedLifetime((appSubscription, monitorSubscription)) {}
    }

    func testAnalyzeRefreshAfterMoveKeepsCurrentDirectoryHistoryAndReport() async throws {
        let removed = try file("removed.bin", bytes: 3), kept = try file("kept.bin", bytes: 5)
        let state = AppState(); defer { state.stop() }
        state.tab = .analyze; state.diskRoot = root; state.diskHistory = [root.deletingLastPathComponent()]
        state.scanDisk(); await state.diskTask?.value
        XCTAssertEqual(state.diskReport?.totalBytes, 8)
        try FileManager.default.removeItem(at: removed.url)
        state.refreshDiskAfterTrash(movedItems: 1)
        XCTAssertTrue(state.diskScanning); XCTAssertNotNil(state.diskReport)
        await state.diskTask?.value
        XCTAssertEqual(state.tab, .analyze); XCTAssertEqual(state.diskRoot, root)
        XCTAssertEqual(state.diskHistory, [root.deletingLastPathComponent()])
        XCTAssertEqual(state.diskReport?.entries.map(\.url), [kept.url])
        XCTAssertEqual(state.diskReport?.totalBytes, 5)
    }

    func testAnalyzeFailedMoveLeavesExistingReportAlone() async throws {
        _ = try file("kept.bin", bytes: 5)
        let state = AppState(); defer { state.stop() }
        state.diskRoot = root; state.scanDisk(); await state.diskTask?.value
        state.refreshDiskAfterTrash(movedItems: 0)
        XCTAssertFalse(state.diskScanning); XCTAssertEqual(state.diskReport?.totalBytes, 5)
    }

    func testAISelectionTotalCacheClearsWithScanInvalidation() async throws {
        let url = try write(".claude/cache/fixture.bin", bytes: 11)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86400)], ofItemAtPath: url.path)
        let scan = await AICleanupScanner(home: root, activity: { [] }).scan()
        XCTAssertFalse(scan.items.isEmpty)
        let state = AppState()
        let current = try XCTUnwrap(state.beginAIScanRequest())
        XCTAssertTrue(state.completeAIScanRequest(scan, packages: nil, id: current.id, days: current.days))
        state.aiSelection = Set(scan.items.map(\.id)).union(["unknown"])
        XCTAssertEqual(state.selectedAIBytes, scan.totalBytes)
        XCTAssertEqual(state.selectedAIItems.map(\.id), scan.items.map(\.id))
        state.invalidateAIScanResults()
        XCTAssertEqual(state.selectedAIBytes, 0); XCTAssertTrue(state.aiIndex.itemsByKind.isEmpty)
        XCTAssertFalse(state.completeAIScanRequest(scan, packages: nil, id: current.id, days: current.days))
    }

    private func aiCandidate(_ id: String, tool: AITool = .cursor, references: [String] = [], kind: AICleanupKind = .databaseSession) throws -> AICleanupCandidate {
        let item = try file(tool.rawValue + "/" + id, bytes: 1)
        var value: [String: Any] = ["tool": tool.rawValue, "kind": kind.rawValue, "url": item.url.absoluteString,
            "title": id, "detail": "fixture", "bytes": 1, "modifiedAt": 0, "sources": [item.url.absoluteString], "signatures": [:]]
        if kind == .databaseSession {
            value["cursorSession"] = ["composerID": id, "rootVersion": 1, "updatedAtMilliseconds": 0, "bytes": 1,
                "rowCount": 1, "referencedIDs": references, "schemaSignature": "fixture"] as [String: Any]
        }
        return try JSONDecoder().decode(AICleanupCandidate.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testAIRelatedSessionIndexHandlesCyclesDirectionAndToolIsolation() throws {
        let a = try aiCandidate("a", references: ["b"]), b = try aiCandidate("b", references: ["a", "c"])
        let c = try aiCandidate("c"), other = try aiCandidate("a", tool: .codex)
        let cache = try aiCandidate("cache", kind: .cache)
        let index = AIResultsIndex([a, b, c, other, cache])
        XCTAssertEqual(index.itemsByKind[.databaseSession]?.count, 4)
        XCTAssertEqual(index.itemsByKind[.cache]?.map(\.id), [cache.id])
        XCTAssertEqual(index.relatedIDs[a.id], [a.id, b.id, c.id])
        XCTAssertEqual(index.relatedIDs[b.id], [a.id, b.id, c.id])
        XCTAssertEqual(index.relatedIDs[c.id], [c.id])
        XCTAssertEqual(index.relatedIDs[other.id], [other.id])
        XCTAssertEqual(index.relatedIDs[cache.id], [cache.id])
        XCTAssertEqual(index.totalBytes, 5)
    }
}
