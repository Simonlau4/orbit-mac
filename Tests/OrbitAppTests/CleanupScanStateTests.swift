import XCTest
import OrbitCore
import Darwin
@testable import Orbit

@MainActor final class CleanupScanStateTests: XCTestCase {
    private func fixture() throws -> (URL, CleanupScan) {
        var physical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &physical) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent("orbit-scan-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("cache.bin")
        try Data("own test cache".utf8).write(to: file)
        let item = try CleanupItem.prepare(at: file)
        return (root, CleanupScan(items: [item], warnings: [], scannedFiles: 1, isPartial: false))
    }

    func testChangingRetentionInvalidatesSelectedResultsAndPendingConfirmation() throws {
        let (root, scan) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "includeRecentCaches")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "includeRecentCaches") } else { UserDefaults.standard.removeObject(forKey: "includeRecentCaches") } }
        let state = AppState(); state.scan = scan; state.showResults = true
        state.selection = [scan.items[0].id]; state.confirmCleaning = true
        state.includeRecentCaches.toggle()
        XCTAssertNil(state.scan); XCTAssertTrue(state.selection.isEmpty)
        XCTAssertFalse(state.confirmCleaning); XCTAssertFalse(state.showResults)
        state.cleanSelection()
        XCTAssertFalse(state.working)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.items[0].url.path))
    }

    func testChangingCategoriesCannotReuseAResultOrItsLateCompletion() throws {
        let (root, scan) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(); let old = try XCTUnwrap(state.beginCleanupScanRequest())
        state.cleanupCategories.remove(.logs)
        XCTAssertFalse(state.completeCleanupScanRequest(scan, id: old))
        XCTAssertNil(state.scan); XCTAssertFalse(state.scanning); XCTAssertFalse(state.showResults)
    }

    func testOlderRequestCannotReplaceNewerScanOrItsSelection() throws {
        let (firstRoot, first) = try fixture(); defer { try? FileManager.default.removeItem(at: firstRoot) }
        let (secondRoot, second) = try fixture(); defer { try? FileManager.default.removeItem(at: secondRoot) }
        let state = AppState(); let old = try XCTUnwrap(state.beginCleanupScanRequest())
        state.invalidateCleanupResults()
        let current = try XCTUnwrap(state.beginCleanupScanRequest())
        XCTAssertTrue(state.completeCleanupScanRequest(second, id: current))
        state.selection = [second.items[0].id]
        XCTAssertFalse(state.completeCleanupScanRequest(first, id: old))
        XCTAssertEqual(state.scan?.items.map(\.id), second.items.map(\.id))
        XCTAssertEqual(state.selection, [second.items[0].id])
    }

    func testRescanDropsOldSelectionAndPreselectsRecommendedResults() throws {
        let (root, scan) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(); state.scan = scan; state.selection = [scan.items[0].id]
        let request = try XCTUnwrap(state.beginCleanupScanRequest())
        XCTAssertNil(state.scan); XCTAssertTrue(state.selection.isEmpty); XCTAssertTrue(state.scanning)
        XCTAssertTrue(state.completeCleanupScanRequest(scan, id: request))
        XCTAssertEqual(state.selection, [scan.items[0].id]); XCTAssertFalse(state.scanning); XCTAssertTrue(state.showResults)
    }
}
