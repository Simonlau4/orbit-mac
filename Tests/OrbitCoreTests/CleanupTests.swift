import XCTest
import Darwin
@testable import OrbitCore

final class CleanupTests: XCTestCase {
    private var fixture: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        var physicalPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(fm.temporaryDirectory.path, &physicalPath) != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        fixture = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
            .appendingPathComponent("orbit-cleanup-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Every test creates its own isolated fixture; no user files are touched.
        if let fixture, fm.fileExists(atPath: fixture.path) { try fm.removeItem(at: fixture) }
    }

    @discardableResult
    private func file(_ path: String, text: String = "fixture content", daysOld: Double = 20) throws -> URL {
        let url = fixture.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86400)], ofItemAtPath: url.path)
        return url
    }

    private var cache: URL { fixture.appendingPathComponent("home/Library/Caches") }
    private var journal: URL { fixture.appendingPathComponent("state/history.json") }
    private var quarantine: URL { fixture.appendingPathComponent("quarantine") }

    private func store(roots: [URL]? = nil) -> TrashStore {
        TrashStore(historyURL: journal, allowedRoots: roots ?? [cache], quarantineURL: quarantine)
    }

    func testScannerFiltersRecentRunningProtectedAndLinkedFiles() async throws {
        let old = try file("home/Library/Caches/com.example.closed/old.bin")
        try file("home/Library/Caches/com.example.closed/recent.bin", daysOld: 1)
        try file("home/Library/Caches/com.example.running/running.bin")
        try file("home/Library/Caches/com.example.closed/session.lock")
        try file("home/Library/Caches/com.example.closed/.git/config")
        try file("home/Library/Caches/com.example.closed/.codex/memory.md")
        let outside = try file("outside/important.txt")
        try fm.createSymbolicLink(at: cache.appendingPathComponent("linked"), withDestinationURL: outside.deletingLastPathComponent())
        let hardlink = cache.appendingPathComponent("hardlink.bin")
        try fm.linkItem(at: outside, to: hardlink)
        let scanner = CleanupScanner(policy: CleanupPolicy(roots: [CleanupRoot(url: cache, category: .appCache, minimumAgeDays: 7)]))
        let result = await scanner.scan(runningBundleIDs: ["com.example.running"])
        XCTAssertEqual(result.items.map(\.url), [old])
        XCTAssertEqual(result.totalBytes, Int64("fixture content".utf8.count))
        XCTAssertGreaterThan(result.scannedFiles, 1)
        XCTAssertFalse(result.isPartial)
    }

    func testBudgetReportsPartialCoverage() async throws {
        try file("home/Library/Caches/a/old.bin")
        try file("home/Library/Caches/b/old.bin")
        let scanner = CleanupScanner(policy: CleanupPolicy(roots: [CleanupRoot(url: cache, category: .appCache, minimumAgeDays: 7)], maximumFiles: 1))
        let result = await scanner.scan()
        XCTAssertTrue(result.isPartial)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertLessThanOrEqual(result.scannedFiles, 1)
    }

    func testProductionScopesOnlyBrowserCacheSubtreesAndOldInstallerFiles() async throws {
        let chrome = try file("home/Library/Application Support/Google/Chrome/Default/Cache/Cache_Data/data_1", daysOld: 9)
        let code = try file("home/Library/Application Support/Google/Chrome/Default/Code Cache/js/source", daysOld: 9)
        let profile = try file("home/Library/Application Support/Google/Chrome/Profile 2/Cache/data", daysOld: 9)
        let edge = try file("home/Library/Application Support/Microsoft Edge/Default/Cache/data", daysOld: 9)
        try file("home/Library/Application Support/Google/Chrome/Default/History", daysOld: 90)
        try file("home/Library/Application Support/Google/Chrome/Default/Cookies", daysOld: 90)
        try file("home/Library/Application Support/Google/Chrome/Guest Profile/Cache/data", daysOld: 90)
        let installer = try file("home/Downloads/Old.dmg", daysOld: 40)
        let package = try file("home/Downloads/Old.PKG", daysOld: 40)
        try file("home/Downloads/Recent.dmg", daysOld: 2)
        try file("home/Downloads/Documents.zip", daysOld: 90)
        try file("home/Downloads/report.pdf", daysOld: 90)
        try file("home/Downloads/Folder/nested.dmg", daysOld: 90)
        let home = fixture.appendingPathComponent("home")
        let result = await CleanupScanner(policy: .production(home: home)).scan()
        XCTAssertEqual(Set(result.items.map(\.url)), Set([chrome, code, profile, edge, installer, package]))
        let chromeGroup = try XCTUnwrap(result.groups.first { $0.name == "Google Chrome · Default" })
        XCTAssertEqual(Set(chromeGroup.items.map(\.url)), Set([chrome, code]))
        XCTAssertEqual(chromeGroup.category, .browserCache)
        XCTAssertFalse(result.isPartial)
    }

    func testRecentCacheModeAndCategoriesDoNotBroadenPersonalScopes() async throws {
        let recentCache = try file("home/Library/Caches/closed/recent", daysOld: 1)
        let recentBuild = try file("home/Library/Developer/Xcode/DerivedData/Project/Build/file", daysOld: 1)
        let npm = try file("home/.npm/_cacache/content/blob", daysOld: 1)
        let pip = try file("home/.cache/pip/http-v2/blob", daysOld: 1)
        try file("home/Library/Logs/recent.log", daysOld: 1)
        try file("home/Downloads/recent.dmg", daysOld: 1)
        try file("home/.cache/huggingface/models/weights.bin", daysOld: 90)
        try file("home/.local/share/custom-runtime/keep.bin", daysOld: 90)
        try file("home/.codex/sessions/session.jsonl", daysOld: 90)
        let home = fixture.appendingPathComponent("home")
        let safe = await CleanupScanner(policy: .production(home: home)).scan()
        XCTAssertTrue(safe.items.isEmpty)
        let recent = await CleanupScanner(policy: .production(home: home, includeRecentCaches: true)).scan()
        XCTAssertEqual(Set(recent.items.map(\.url)), Set([recentCache, recentBuild, npm, pip]))
        let packages = await CleanupScanner(policy: .production(home: home, includeRecentCaches: true, categories: [.packageCache])).scan()
        XCTAssertEqual(Set(packages.items.map(\.url)), Set([npm, pip]))
        XCTAssertEqual(Set(packages.groups.map(\.name)), Set(["npm", "pip"]))
        XCTAssertTrue(packages.items.allSatisfy { $0.category == .packageCache })
    }

    func testRunningBrowserAndLinkedProfileRemainExcluded() async throws {
        try file("home/Library/Application Support/Google/Chrome/Default/Cache/old", daysOld: 30)
        let home = fixture.appendingPathComponent("home")
        let running = await CleanupScanner(policy: .production(home: home)).scan(runningBundleIDs: ["com.google.Chrome"])
        XCTAssertTrue(running.items.isEmpty)
        let outside = try file("outside/Cache/important", daysOld: 30)
        let browser = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try fm.createSymbolicLink(at: browser.appendingPathComponent("Profile 3"), withDestinationURL: outside.deletingLastPathComponent().deletingLastPathComponent())
        let linked = await CleanupScanner(policy: .production(home: home)).scan()
        XCTAssertFalse(linked.items.contains { $0.url.path.contains("Profile 3") })
        XCTAssertGreaterThan(linked.blockedCount, 0)
        XCTAssertTrue(linked.isPartial)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "fixture content")
    }

    func testOverlappingScopesAreCountedOnceAndGroupsPreserveTotals() async throws {
        let old = try file("home/Library/Caches/Example/old.bin", text: "older", daysOld: 20)
        try file("home/Library/Caches/Example/recent.bin", text: "new", daysOld: 1)
        let standalone = try file("home/Library/Caches/standalone.bin", text: "root", daysOld: 20)
        let specific = cache.appendingPathComponent("Example")
        let policy = CleanupPolicy(roots: [
            CleanupRoot(url: cache, category: .appCache, minimumAgeDays: 7),
            CleanupRoot(url: specific, category: .browserCache, minimumAgeDays: 7, label: "Example browser"),
            CleanupRoot(url: specific, category: .browserCache, minimumAgeDays: 7, label: "duplicate")
        ])
        let result = await CleanupScanner(policy: policy).scan()
        XCTAssertEqual(Set(result.items.map(\.url)), Set([old, standalone]))
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.scannedFiles, 3)
        XCTAssertEqual(result.scannedBytes, 12)
        XCTAssertEqual(result.totalBytes, 9)
        XCTAssertEqual(result.groups.reduce(0) { $0 + $1.bytes }, result.totalBytes)
        XCTAssertEqual(result.groups.flatMap(\.items).count, result.items.count)
        XCTAssertEqual(result.items.first { $0.url == old }?.category, .browserCache)
    }

    func testWarningsAreBoundedWhileBlockedCountRetainsAllFailures() async throws {
        let outside = try file("outside/keep.bin")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        var roots: [CleanupRoot] = []
        for index in 0..<30 {
            let link = cache.appendingPathComponent("linked-\(index)")
            try fm.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
            roots.append(CleanupRoot(url: link, category: .appCache, minimumAgeDays: 7))
        }
        let result = await CleanupScanner(policy: CleanupPolicy(roots: roots)).scan()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.blockedCount, 30)
        XCTAssertLessThanOrEqual(result.warnings.count, 12)
        XCTAssertTrue(result.isPartial)
    }

    func testLargeSelectionKeepsDurableRecordOrderAndRestores() async throws {
        var items: [CleanupItem] = []
        for index in 0..<30 { items.append(try CleanupItem.prepare(at: file("home/Library/Caches/app/\(index).bin"))) }
        let trash = store()
        let batch = try await trash.moveToTrash(items)
        XCTAssertEqual(batch.records.count, 30)
        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(Set(batch.records.map(\.originalURL)), Set(items.map(\.url)))
        for record in batch.records { try await trash.restore(record.id) }
        XCTAssertTrue(items.allSatisfy { fm.fileExists(atPath: $0.url.path) })
        let history = try await trash.history()
        XCTAssertEqual(history.filter { $0.state == .restored }.count, 30)
    }

    func testMoveRestoreAndDurableHistory() async throws {
        let source = try file("home/Library/Caches/sample/old.bin")
        let item = try CleanupItem.prepare(at: source)
        let first = store()
        let batch = try await first.moveToTrash([item])
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        let record = try XCTUnwrap(batch.records.first)
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(record.trashedURL).path))
        XCTAssertEqual(batch.totalBytes, item.bytes)
        let reloaded = store()
        let before = try await reloaded.history()
        XCTAssertEqual(before.first?.state, .trashed)
        try await reloaded.restore(record.id)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "fixture content")
        let after = try await first.history()
        XCTAssertEqual(after.first?.state, .restored)
        XCTAssertNotNil(after.first?.restoredAt)
        XCTAssertEqual(try fm.attributesOfItem(atPath: journal.path)[.posixPermissions] as? Int, 0o600)
    }

    func testChangedFileAndOutOfScopeAreRejectedWhileValidItemSucceeds() async throws {
        let changed = try file("home/Library/Caches/a.bin")
        let changedItem = try CleanupItem.prepare(at: changed)
        try Data("changed after scan".utf8).write(to: changed)
        let outside = try file("home/Library/Caches-elsewhere/important.txt")
        let valid = try file("home/Library/Caches/b.bin")
        let batch = try await store().moveToTrash([changedItem, CleanupItem.prepare(at: outside), CleanupItem.prepare(at: valid)])
        XCTAssertEqual(batch.failures.count, 2)
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: changed.path))
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
        XCTAssertFalse(fm.fileExists(atPath: valid.path))
    }

    func testRootItselfAndProtectedAgentFilesAreRejected() async throws {
        try file("home/Library/Caches/normal.bin")
        let rootItem = try CleanupItem.prepare(at: cache)
        let result = try await store().moveToTrash([rootItem])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
        let protected = try file("home/.codex/sessions/transcript.jsonl")
        XCTAssertThrowsError(try CleanupItem.prepare(at: protected))
        let skills = try file("home/.agents/skills/example/SKILL.md")
        XCTAssertThrowsError(try CleanupItem.prepare(at: skills))
        XCTAssertThrowsError(try CleanupItem.prepare(at: URL(fileURLWithPath: "/System")))
    }

    func testSymlinkInsertedAfterScanCannotEscapeScope() async throws {
        let source = try file("home/Library/Caches/app/old.bin")
        let item = try CleanupItem.prepare(at: source)
        let outside = try file("outside/old.bin", text: "important")
        let parent = source.deletingLastPathComponent()
        try fm.moveItem(at: parent, to: cache.appendingPathComponent("moved-app"))
        try fm.createSymbolicLink(at: parent, withDestinationURL: outside.deletingLastPathComponent())
        let result = try await store().moveToTrash([item])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "important")
    }

    func testRestoreNeverOverwritesExistingOriginal() async throws {
        let source = try file("home/Library/Caches/old.bin")
        let trash = store()
        let batch = try await trash.moveToTrash([CleanupItem.prepare(at: source)])
        let record = try XCTUnwrap(batch.records.first)
        try Data("replacement".utf8).write(to: source)
        do {
            try await trash.restore(record.id)
            XCTFail("Restore should reject an occupied original path")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无法覆盖恢复"))
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement")
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(record.trashedURL).path))
    }

    func testRestoreRejectsChangedParentLink() async throws {
        let source = try file("home/Library/Caches/app/old.bin")
        let trash = store()
        let batch = try await trash.moveToTrash([CleanupItem.prepare(at: source)])
        let record = try XCTUnwrap(batch.records.first)
        let parent = source.deletingLastPathComponent()
        try fm.moveItem(at: parent, to: cache.appendingPathComponent("original-app"))
        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: parent, withDestinationURL: outside)
        do {
            try await trash.restore(record.id)
            XCTFail("Restore should reject a linked parent")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("符号链接"))
        }
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("old.bin").path))
    }

    func testCorruptHistoryFailsBeforeAnyFileMoves() async throws {
        let source = try file("home/Library/Caches/old.bin")
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: journal)
        do {
            _ = try await store().moveToTrash([CleanupItem.prepare(at: source)])
            XCTFail("Corrupt history must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("历史损坏"))
        }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "invalid json")
    }

    func testHistorySymlinkFailsClosed() async throws {
        let source = try file("home/Library/Caches/old.bin")
        let target = try file("outside/keep.json", text: "keep")
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: journal, withDestinationURL: target)
        do {
            _ = try await store().moveToTrash([CleanupItem.prepare(at: source)])
            XCTFail("Linked history must fail closed")
        } catch { }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testExplicitApplicationDirectoryCanMoveAndRestore() async throws {
        try file("Applications/Fixture.app/Contents/Info.plist")
        let application = fixture.appendingPathComponent("Applications/Fixture.app")
        let trash = store(roots: [fixture.appendingPathComponent("Applications")])
        let batch = try await trash.moveToTrash([CleanupItem.prepare(at: application)])
        let record = try XCTUnwrap(batch.records.first)
        XCTAssertFalse(fm.fileExists(atPath: application.path))
        try await trash.restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: application.appendingPathComponent("Contents/Info.plist").path))
    }

    func testInterruptedMoveIntentIsReconciledFromDurableRecord() async throws {
        let source = try file("home/Library/Caches/old.bin")
        let trash = store()
        let batch = try await trash.moveToTrash([CleanupItem.prepare(at: source)])
        let record = try XCTUnwrap(batch.records.first)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        var records = try XCTUnwrap(data["records"] as? [[String: Any]])
        records[0]["state"] = "pending"
        records[0].removeValue(forKey: "trashedFingerprint")
        data["records"] = records
        try JSONSerialization.data(withJSONObject: data).write(to: journal)
        let recovered = try await store().history()
        XCTAssertEqual(recovered.first?.state, .trashed)
        try await trash.restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testDuplicateSelectionIsMovedOnlyOnce() async throws {
        let source = try file("home/Library/Caches/old.bin")
        let item = try CleanupItem.prepare(at: source)
        let batch = try await store().moveToTrash([item, item])
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batch.totalBytes, item.bytes)
    }

    func testInterruptedRestoreBeforeMoveCanRetry() async throws {
        let source = try file("home/Library/Caches/old.bin")
        let trash = store()
        let batch = try await trash.moveToTrash([CleanupItem.prepare(at: source)])
        let record = try XCTUnwrap(batch.records.first)
        try rewriteFirstRecordState("restoring")
        let recovered = try await store().history()
        XCTAssertEqual(recovered.first?.state, .trashed)
        XCTAssertTrue(recovered.first?.message?.contains("可重试恢复") == true)
        try await trash.restore(record.id)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "fixture content")
    }

    func testInterruptedRestoreAfterMoveIsMarkedRestored() async throws {
        let source = try file("home/Library/Caches/old.bin")
        let trash = store()
        let batch = try await trash.moveToTrash([CleanupItem.prepare(at: source)])
        let record = try XCTUnwrap(batch.records.first)
        try await trash.restore(record.id)
        try rewriteFirstRecordState("restoring")
        let recovered = try await store().history()
        XCTAssertEqual(recovered.first?.state, .restored)
        XCTAssertNotNil(recovered.first?.restoredAt)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "fixture content")
    }

    func testNativeMacOSTrashPersistsActualURLAndRestoresFixture() async throws {
        let filename = "Orbit-integration-" + UUID().uuidString + ".txt"
        let content = "Orbit native macOS Trash integration fixture " + UUID().uuidString
        let source = try file("home/Library/Caches/" + filename, text: content)
        let nativeTrash = TrashStore(historyURL: journal, allowedRoots: [cache])
        let before = try CleanupItem.prepare(at: source)
        var actualTrashURL: URL?
        defer {
            // Recover only the unique file created by this test if an assertion/restore fails.
            if let actualTrashURL, fm.fileExists(atPath: actualTrashURL.path), !fm.fileExists(atPath: source.path) {
                try? fm.moveItem(at: actualTrashURL, to: source)
            }
        }
        let batch = try await nativeTrash.moveToTrash([before])
        XCTAssertTrue(batch.failures.isEmpty, batch.failures.map(\.message).joined(separator: "; "))
        let record = try XCTUnwrap(batch.records.first)
        let destination = try XCTUnwrap(record.trashedURL)
        actualTrashURL = destination
        XCTAssertNotEqual(destination.deletingLastPathComponent(), quarantine)
        XCTAssertTrue(destination.pathComponents.contains(".Trash") || destination.pathComponents.contains(".Trashes"))
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), content)
        XCTAssertEqual(try CleanupItem.prepare(at: destination).fingerprint.inode, before.fingerprint.inode)
        let reloaded = TrashStore(historyURL: journal, allowedRoots: [cache])
        let history = try await reloaded.history()
        XCTAssertEqual(history.first?.trashedURL, destination)
        XCTAssertEqual(history.first?.state, .trashed)
        try await reloaded.restore(record.id)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), content)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        let restored = try await nativeTrash.history()
        XCTAssertEqual(restored.first?.state, .restored)
    }

    private func rewriteFirstRecordState(_ state: String) throws {
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        var records = try XCTUnwrap(data["records"] as? [[String: Any]])
        records[0]["state"] = state
        records[0].removeValue(forKey: "restoredAt")
        data["records"] = records
        try JSONSerialization.data(withJSONObject: data).write(to: journal)
    }
}
