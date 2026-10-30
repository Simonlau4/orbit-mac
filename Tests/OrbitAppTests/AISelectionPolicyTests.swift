import XCTest
import Darwin
import OrbitCore
@testable import Orbit

@MainActor
final class AISelectionPolicyTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var home: URL { root.appendingPathComponent("home") }
    private var recovery: URL { root.appendingPathComponent("recovery") }

    override func setUpWithError() throws {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(fm.temporaryDirectory.path, &path) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("orbit-ai-policy-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
    }
    private func state() -> AppState {
        AppState(aiStore: AICleanupStore(home: home, recoveryRoot: recovery, activity: { [] }),
                 aiPackageStore: AIPackageStore(home: home, locations: AIPackageLocations(npmPrefixes: [], homebrewPrefixes: []),
                    recoveryRoot: root.appendingPathComponent("package-recovery"), activity: { [] }))
    }
    @discardableResult private func file(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("isolated policy fixture".utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86400)], ofItemAtPath: url.path)
        return url
    }
    private func conversationScan() async throws -> (AICleanupScan, URL) {
        let url = try file(".claude/projects/fixture/12345678-1234-4234-8234-123456789abc.jsonl")
        let scan = await AICleanupScanner(home: home, activity: { [] }).scan(sessionRetentionDays: 30)
        XCTAssertEqual(scan.items.count, 1)
        return (scan, url)
    }
    @discardableResult private func accept(_ scan: AICleanupScan, into state: AppState, days: Int) throws -> UUID {
        state.aiRetentionDays = days
        let request = try XCTUnwrap(state.beginAIScanRequest())
        XCTAssertTrue(state.completeAIScanRequest(scan, packages: nil, id: request.id, days: request.days))
        return request.id
    }
    private func assertNoCleanup(_ state: AppState, file: URL) async throws {
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        let history = try await state.aiStore.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testRetentionChangeInvalidatesResultAndSelection() async throws {
        let state = state(); defer { state.stop() }
        XCTAssertEqual(state.aiRetentionDays, 0)
        let (scan, file) = try await conversationScan()
        _ = try accept(scan, into: state, days: 30)
        state.aiSelection = Set(scan.items.map(\.id))
        XCTAssertEqual(state.selectedAIItems.count, 1)
        state.aiRetentionDays = 0
        XCTAssertNil(state.aiScan)
        XCTAssertTrue(state.aiSelection.isEmpty)
        XCTAssertFalse(state.aiResultsAreCurrent)
        XCTAssertTrue(state.selectedAIItems.isEmpty)
        try await assertNoCleanup(state, file: file)
    }

    func testRescanHidesOldRowsAndCompletesWithNoSelectedItems() async throws {
        let state = state(); defer { state.stop() }
        let (scan, file) = try await conversationScan()
        _ = try accept(scan, into: state, days: 30)
        state.aiSelection = Set(scan.items.map(\.id))
        let request = try XCTUnwrap(state.beginAIScanRequest())
        XCTAssertTrue(state.aiScanning)
        XCTAssertNil(state.aiScan)
        XCTAssertTrue(state.aiSelection.isEmpty)
        // A delayed event from the old view must not become a fresh selection.
        state.aiSelection = Set(scan.items.map(\.id))
        XCTAssertTrue(state.selectedAIItems.isEmpty)
        state.selectRelatedAISessions(try XCTUnwrap(scan.items.first))
        XCTAssertTrue(state.completeAIScanRequest(scan, packages: nil, id: request.id, days: request.days))
        XCTAssertTrue(state.aiSelection.isEmpty)
        XCTAssertTrue(state.aiResultsAreCurrent)
        try await assertNoCleanup(state, file: file)
    }

    func testOldScanCompletionCannotOverwriteNewRequestOrClearItsProgress() async throws {
        let state = state(); defer { state.stop() }
        let (scan, file) = try await conversationScan()
        state.aiRetentionDays = 30
        let old = try XCTUnwrap(state.beginAIScanRequest())
        state.aiRetentionDays = 90
        state.aiRetentionDays = 30
        let current = try XCTUnwrap(state.beginAIScanRequest())
        XCTAssertNotEqual(old.id, current.id)
        XCTAssertFalse(state.completeAIScanRequest(scan, packages: nil, id: old.id, days: old.days))
        XCTAssertTrue(state.aiScanning)
        XCTAssertNil(state.aiScan)
        XCTAssertTrue(state.completeAIScanRequest(scan, packages: nil, id: current.id, days: current.days))
        XCTAssertFalse(state.aiScanning)
        try await assertNoCleanup(state, file: file)
    }

    func testOldConfirmationCannotConsumeTheNewScansSelection() async throws {
        let state = state(); defer { state.stop() }
        let (scan, file) = try await conversationScan()
        let oldID = try accept(scan, into: state, days: 30)
        state.invalidateAIScanResults()
        _ = try accept(scan, into: state, days: 30)
        state.aiSelection = Set(scan.items.map(\.id))
        state.cleanAI(expectedRequestID: oldID)
        XCTAssertFalse(state.working)
        XCTAssertEqual(state.notice?.title, "扫描条件已变化")
        try await assertNoCleanup(state, file: file)
    }

    func testPolicyChangeBeforeQueuedCleanupRunsPreventsMutation() async throws {
        let state = state(); defer { state.stop() }
        let (scan, file) = try await conversationScan()
        let id = try accept(scan, into: state, days: 30)
        state.aiSelection = Set(scan.items.map(\.id))
        state.cleanAI(expectedRequestID: id)
        XCTAssertTrue(state.working)
        let operation = try XCTUnwrap(state.aiTask)
        state.aiRetentionDays = 0
        await operation.value
        XCTAssertFalse(state.working)
        XCTAssertEqual(state.notice?.title, "扫描条件已变化")
        try await assertNoCleanup(state, file: file)
    }

    func testPreserveAllPolicyRejectsAnInconsistentConversationResult() async throws {
        let state = state(); defer { state.stop() }
        let (scan, file) = try await conversationScan()
        let id = try accept(scan, into: state, days: 0)
        state.aiSelection = Set(scan.items.map(\.id))
        state.cleanAI(expectedRequestID: id)
        XCTAssertFalse(state.working)
        XCTAssertEqual(state.notice?.title, "对话已保留")
        XCTAssertTrue(state.aiSelection.isEmpty)
        try await assertNoCleanup(state, file: file)
    }

    func testCurrentPreserveAllPolicyCanStillProcessExplicitlySelectedFixtureCache() async throws {
        let state = state(); defer { state.stop() }
        let cache = try file(".claude/cache/fixture.bin")
        let scan = await AICleanupScanner(home: home, activity: { [] }).scan()
        let id = try accept(scan, into: state, days: 0)
        state.aiSelection = Set(scan.items.map(\.id))
        state.cleanAI(expectedRequestID: id)
        await state.aiTask?.value
        XCTAssertFalse(state.working)
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        let history = try await state.aiStore.history()
        XCTAssertEqual(history.count, 1)
        try await state.aiStore.restore(try XCTUnwrap(history.first?.id))
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
    }
}
