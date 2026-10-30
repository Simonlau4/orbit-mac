import XCTest
import Darwin
@testable import OrbitCore

final class AICursorVersionsTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var recovery: URL { root.appendingPathComponent("recovery") }
    private let nested = "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local"
    private let oldDate = Date().addingTimeInterval(-100 * 86400)
    private var versions: URL { home.appendingPathComponent(nested + "/share/cursor-agent/versions") }
    private var entry: URL { home.appendingPathComponent(nested + "/bin/cursor-agent") }
    override func setUpWithError() throws {
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-ai-cursor-versions-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }
    @discardableResult private func version(_ name: String) throws -> URL {
        let directory = versions.appendingPathComponent(name)
        let chunk = directory.appendingPathComponent("dist/chunk.js")
        try fm.createDirectory(at: chunk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture program".utf8).write(to: directory.appendingPathComponent("cursor-agent"))
        try Data("fixture chunk".utf8).write(to: chunk)
        for path in [directory, directory.appendingPathComponent("cursor-agent"), chunk.deletingLastPathComponent(), chunk] {
            try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: path.path)
        }
        return directory
    }
    private func link(_ url: URL, to target: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { try fm.removeItem(at: url) }
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
    }
    private func scanner(activity: @escaping AIActivityProvider = { [] }, maximum: Int = 10_000) -> AICleanupScanner {
        AICleanupScanner(home: home, maximumFiles: maximum, activity: activity)
    }
    private func store(activity: @escaping AIActivityProvider = { [] }) -> AICleanupStore {
        AICleanupStore(home: home, recoveryRoot: recovery, activity: activity)
    }

    func testExactNestedRootFindsTwoOldVersionsAndRestoresWholeDirectories() async throws {
        let oldest = try version("2026.07.23-e383d2b"), older = try version("2026.10.14-941492e")
        let current = try version("2026.10.16-e3cb207")
        try link(entry, to: current.appendingPathComponent("cursor-agent"))
        let result = await scanner().scan()
        let items = result.items.filter { $0.kind == .oldVersion && $0.tool == .cursor }
        XCTAssertEqual(Set(items.map { $0.url.path }), Set([oldest.path, older.path]))
        XCTAssertTrue(result.retained.contains { $0.url.path == current.path && $0.reason.contains("当前或最新") })
        XCTAssertFalse(result.isPartial, result.warnings.joined(separator: "\n"))
        let service = store(), record = try await service.apply(items)
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertFalse(fm.fileExists(atPath: oldest.path)); XCTAssertFalse(fm.fileExists(atPath: older.path))
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        try await service.restore(record.id)
        XCTAssertEqual(try String(contentsOf: oldest.appendingPathComponent("cursor-agent"), encoding: .utf8), "fixture program")
        XCTAssertEqual(try String(contentsOf: older.appendingPathComponent("dist/chunk.js"), encoding: .utf8), "fixture chunk")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: entry.path), current.appendingPathComponent("cursor-agent").path)
    }

    func testCurrentLatestAndSymbolicVersionEntriesAreKeptAndRechecked() async throws {
        let candidate = try version("2026.06.01-aabbccd"), current = try version("2026.07.23-e383d2b")
        let markedLatest = try version("2026.10.14-941492e"), newest = try version("2026.10.16-e3cb207")
        try link(entry, to: current.appendingPathComponent("cursor-agent"))
        try link(versions.appendingPathComponent("current"), to: current)
        try link(versions.appendingPathComponent("latest"), to: markedLatest)
        let symbolic = versions.appendingPathComponent("2026.05.01-deadbee")
        try link(symbolic, to: newest)
        let result = await scanner().scan()
        let items = result.items.filter { $0.kind == .oldVersion }
        XCTAssertEqual(items.map { $0.url.path }, [candidate.path])
        for kept in [current, markedLatest, newest, symbolic] {
            XCTAssertTrue(result.retained.contains { $0.url.path == kept.path }, kept.path)
        }
        try link(versions.appendingPathComponent("latest"), to: candidate)
        do { _ = try await store().apply(items); XCTFail("latest pointer changed after scan") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: candidate.path))
    }

    func testRunningCursorKeepsNestedVersionsDuringScanApplyAndRestore() async throws {
        let older = try version("2026.07.23-e383d2b"), current = try version("2026.10.16-e3cb207")
        try link(entry, to: current.appendingPathComponent("cursor-agent"))
        let active = await scanner(activity: { [.cursor] }).scan()
        XCTAssertFalse(active.items.contains { $0.kind == .oldVersion })
        XCTAssertTrue(active.retained.contains { $0.url.path == older.path && $0.reason.contains("可能使用") })
        let idle = await scanner().scan(), item = try XCTUnwrap(idle.items.first { $0.kind == .oldVersion })
        do { _ = try await store(activity: { [.cursor] }).apply([item]); XCTFail("active tool") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: older.path))
        let service = store(), record = try await service.apply([item])
        do { try await store(activity: { [.cursor] }).restore(record.id); XCTFail("active tool restore") } catch {}
        XCTAssertFalse(fm.fileExists(atPath: older.path))
        try await service.restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: older.path))
    }

    func testLatestDateBuildsAndUnknownCurrentPointerArePreserved() async throws {
        let older = try version("2026.07.23-e383d2b")
        let first = try version("2026.10.16-1111111"), second = try version("2026.10.16-eeeeeee")
        try link(entry, to: first.appendingPathComponent("cursor-agent"))
        let result = await scanner().scan()
        XCTAssertEqual(result.items.filter { $0.kind == .oldVersion }.map { $0.url.path }, [older.path])
        XCTAssertTrue(result.retained.contains { $0.url.path == second.path })
        try link(entry, to: home.appendingPathComponent("missing-cursor-agent"))
        let unknown = await scanner().scan()
        XCTAssertFalse(unknown.items.contains { $0.kind == .oldVersion })
        XCTAssertTrue(unknown.retained.contains { $0.reason.contains("无法确认当前版本") })
    }

    func testNestedVersionDiscoveryConsumesTheGlobalBudget() async throws {
        _ = try version("2026.07.23-e383d2b"); _ = try version("2026.10.14-941492e"); _ = try version("2026.10.16-e3cb207")
        let limited = await scanner(maximum: 2).scan()
        XCTAssertTrue(limited.isPartial)
        XCTAssertLessThanOrEqual(limited.scannedFiles, 2)
        XCTAssertTrue(limited.items.isEmpty)
        XCTAssertTrue(limited.warnings.contains { $0.contains("上限") })
    }

    func testGlobalCursorAgentEntryProtectsTheNestedVersionItActuallyUses() async throws {
        let globalCurrent = try version("2026.07.23-e383d2b"), oldUnused = try version("2026.10.14-941492e")
        let newest = try version("2026.10.16-e3cb207")
        try link(entry, to: newest.appendingPathComponent("cursor-agent"))
        try link(home.appendingPathComponent(".local/bin/cursor-agent"), to: globalCurrent.appendingPathComponent("cursor-agent"))
        let result = await scanner().scan()
        XCTAssertEqual(result.items.filter { $0.kind == .oldVersion }.map { $0.url.path }, [oldUnused.path])
        XCTAssertTrue(result.retained.contains { $0.url.path == globalCurrent.path && $0.reason.contains("当前或最新") })
    }

    func testCacheCaseAliasOfOneInodeIsCountedOnceAndRestores() async throws {
        let actual = home.appendingPathComponent("Library/Application Support/Cursor/cache")
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        let file = actual.appendingPathComponent("fixture.bin"), payload = Data("one physical cache".utf8)
        try payload.write(to: file); try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        let configured = home.appendingPathComponent("Library/Application Support/Cursor/Cache")
        var first = stat(), second = stat()
        guard lstat(configured.path, &first) == 0 else { throw XCTSkip("此磁盘区分Cache与cache，未构成大小写别名。") }
        XCTAssertEqual(lstat(actual.path, &second), 0)
        XCTAssertEqual(first.st_dev, second.st_dev); XCTAssertEqual(first.st_ino, second.st_ino)
        let result = await scanner().scan(), items = result.items.filter { $0.kind == .cache && $0.tool == .cursor }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.reduce(Int64(0)) { $0 + $1.bytes }, Int64(payload.count))
        let service = store(), record = try await service.apply(items)
        try await service.restore(record.id)
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }
}
