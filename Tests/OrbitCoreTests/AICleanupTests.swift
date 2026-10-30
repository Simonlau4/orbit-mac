import XCTest
import Darwin
@testable import OrbitCore

final class AICleanupTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var recovery: URL { root.appendingPathComponent("recovery") }
    private let old = Date().addingTimeInterval(-100 * 86400)
    private let sessionID = "12345678-1234-4234-8234-123456789abc"

    override func setUpWithError() throws {
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(fm.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-ai-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
    }
    @discardableResult private func file(_ relative: String, _ text: String = "isolated fixture", old: Bool = true) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if old { try fm.setAttributes([.modificationDate: self.old], ofItemAtPath: url.path) }
        return url
    }
    private func scanner(activity: @escaping AIActivityProvider = { [] }, maximum: Int = 10000) -> AICleanupScanner {
        AICleanupScanner(home: home, maximumFiles: maximum, activity: activity)
    }
    private func store(activity: @escaping AIActivityProvider = { [] }) -> AICleanupStore {
        AICleanupStore(home: home, recoveryRoot: recovery, activity: activity)
    }
    private func command(_ path: String, _ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "fixture-command", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]) }
        return String(data: data, encoding: .utf8) ?? ""
    }
    @discardableResult private func sqlite(_ path: URL, _ sql: String) throws -> String { try command("/usr/bin/sqlite3", [path.path, sql]) }
    private func codexFixture() throws -> (URL, URL, URL) {
        let session = try file(".codex/archived_sessions/rollout-2026-01-01T00-00-00-" + sessionID + ".jsonl", "{\"fixture\":true}\n")
        let database = home.appendingPathComponent(".codex/state_5.sqlite")
        try sqlite(database, "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL); INSERT INTO threads VALUES ('\(sessionID)','\(session.path)');")
        let index = try file(".codex/session_index.jsonl", "{\"id\":\"\(sessionID)\",\"thread_name\":\"Fixture\"}\n")
        return (session, database, index)
    }

    func testCacheScopePreservesMemoryAndSessionsRemainOptIn() async throws {
        let cache = try file(".claude/cache/old.bin")
        let session = try file(".claude/projects/project/" + sessionID + ".jsonl")
        let memory = try file(".claude/projects/project/memory/MEMORY.md")
        try file(".claude/plans/keep.md"); try file(".claude/skills/keep/SKILL.md")
        let scan = await scanner().scan()
        XCTAssertEqual(scan.items.map(\.url), [cache])
        XCTAssertTrue(scan.retained.contains { $0.url == session && $0.reason.contains("天数") })
        XCTAssertFalse(scan.items.contains { $0.url == memory })
        let opted = await scanner().scan(sessionRetentionDays: 30)
        XCTAssertEqual(Set(opted.items.map(\.url)), Set([cache, session]))
        XCTAssertFalse(opted.isPartial)
    }

    func testStagedApplicationInCacheIsACandidateWhileLooseSkillsStayProtected() async throws {
        let sparkle = home.appendingPathComponent("Library/Caches/com.openai.codex/org.sparkle-project.Sparkle")
        let staged = try file("Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation/x/ChatGPT.app/Contents/Resources/skills/a.md")
        let loose = try file("Library/Caches/com.openai.codex/loose/skills/keep.md")
        // Folders took today's date while files were written; age both trees.
        for (leaf, top) in [(staged, sparkle), (loose, sparkle.deletingLastPathComponent().appendingPathComponent("loose"))] {
            var directory = leaf.deletingLastPathComponent()
            while directory.path.count >= top.path.count {
                try fm.setAttributes([.modificationDate: old], ofItemAtPath: directory.path); directory.deleteLastPathComponent()
            }
        }
        let scan = await scanner().scan()
        XCTAssertTrue(scan.items.contains { $0.url.path == sparkle.path && $0.kind == .cache })
        XCTAssertFalse(scan.items.contains { $0.url.lastPathComponent == "loose" })
    }

    func testRealMoveAndRestoreRoundTripAndDurableHistory() async throws {
        let cache = try file(".claude/cache/old.bin", "cache bytes")
        let scanned = await scanner().scan()
        let item = try XCTUnwrap(scanned.items.first)
        let service = store()
        let record = try await service.apply([item])
        XCTAssertEqual(record.state, .stored)
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        let reopened = store()
        let initialHistory = try await reopened.history()
        XCTAssertEqual(initialHistory.count, 1)
        try await reopened.restore(record.id)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "cache bytes")
        let restoredHistory = try await reopened.history()
        XCTAssertEqual(restoredHistory.first?.state, .restored)
    }

    func testChildChangedAfterDirectoryScanIsRejected() async throws {
        let child = try file(".claude/cache/blob/one.bin")
        let folder = child.deletingLastPathComponent()
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        let scanned = await scanner().scan()
        let item = try XCTUnwrap(scanned.items.first)
        try Data("changed".utf8).write(to: child)
        do { _ = try await store().apply([item]); XCTFail("changed tree admitted") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: child.path))
    }

    func testSymlinksHardlinksAndProtectedSubtreesAreRetained() async throws {
        let target = try file("outside/private.txt")
        let cache = home.appendingPathComponent(".claude/cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cache.appendingPathComponent("linked"), withDestinationURL: target)
        try fm.linkItem(at: target, to: cache.appendingPathComponent("hardlink"))
        try file(".claude/cache/unsafe/memories/keep.md")
        let result = await scanner().scan()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "isolated fixture")
    }

    func testRunningToolIsRecheckedBeforeMutationAndRecoveryRefusesOverwrite() async throws {
        let cache = try file(".claude/cache/old.bin")
        let scan = await scanner(activity: { [.claude] }).scan()
        XCTAssertTrue(scan.items.isEmpty)
        XCTAssertTrue(scan.retained.contains { $0.reason.contains("可能使用") })
        let scanned = await scanner().scan()
        let item = try XCTUnwrap(scanned.items.first)
        do { _ = try await store(activity: { [.claude] }).apply([item]); XCTFail("running tool admitted") } catch {}
        let service = store(), record = try await service.apply([item])
        try Data("new file".utf8).write(to: cache)
        do { try await service.restore(record.id); XCTFail("new file overwritten") } catch {}
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "new file")
    }

    func testCurrentAndNewestCLIVersionsAreKeptAndSymlinkChangeIsRechecked() async throws {
        let oldProgram = try file(".local/share/claude/versions/2.1.1")
        try file(".local/share/claude/versions/2.1.2")
        try file(".local/share/claude/versions/2.1.3")
        let link = home.appendingPathComponent(".local/bin/claude")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".local/share/claude/versions/2.1.2"))
        let scan = await scanner().scan()
        XCTAssertEqual(scan.items.map(\.url), [oldProgram])
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: oldProgram)
        do { _ = try await store().apply(scan.items); XCTFail("current CLI version removed") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: oldProgram.path))
    }

    func testCodexSessionsSynchronizeIndexAndDatabaseAndRestoreOffline() async throws {
        let (session, database, index) = try codexFixture()
        let result = await scanner().scan(sessionRetentionDays: 30)
        let item = try XCTUnwrap(result.items.first { $0.kind == .session })
        let service = store(), record = try await service.apply([item])
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertFalse(fm.fileExists(atPath: session.path))
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM threads;").trimmingCharacters(in: .whitespacesAndNewlines), "0")
        XCTAssertEqual(try Data(contentsOf: index).count, 0)
        try await service.restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: session.path))
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM threads;").trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertTrue(try String(contentsOf: index, encoding: .utf8).contains(sessionID))
    }

    func testCodexUnknownIndexOrRunningProcessIsRetained() async throws {
        let session = try file(".codex/archived_sessions/rollout-2026-01-01T00-00-00-" + sessionID + ".jsonl")
        let unknown = await scanner().scan(sessionRetentionDays: 1)
        XCTAssertTrue(unknown.items.isEmpty)
        XCTAssertTrue(unknown.retained.contains { $0.url == session && $0.reason.contains("索引") })
        _ = try codexFixture()
        let busy = await scanner(activity: { [.codex] }).scan(sessionRetentionDays: 1)
        XCTAssertTrue(busy.items.isEmpty)
    }

    func testDatabaseCompactionPreservesAllRowsAndRefusesToOverwriteNewRows() async throws {
        let (_, database, _) = try codexFixture()
        try sqlite(database, "CREATE TABLE waste(data BLOB); INSERT INTO waste VALUES(zeroblob(400000)); DELETE FROM waste;")
        let sizeBefore = (try fm.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.int64Value ?? 0
        let service = store(), record = try await service.compactDatabase(at: database, tool: .codex)
        XCTAssertEqual(record.state, .stored, record.message)
        let sizeAfter = (try fm.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertLessThan(sizeAfter, sizeBefore)
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM threads;").trimmingCharacters(in: .whitespacesAndNewlines), "1")
        try sqlite(database, "INSERT INTO threads VALUES ('new','/fixture/new');")
        do { try await service.restore(record.id); XCTFail("new database content overwritten") } catch {}
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM threads;").trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testDatabaseCompactionCanRestoreUnmodifiedOriginal() async throws {
        let (_, database, _) = try codexFixture()
        try sqlite(database, "CREATE TABLE waste(data BLOB); INSERT INTO waste VALUES(zeroblob(400000)); DELETE FROM waste;")
        let before = try Data(contentsOf: database)
        let service = store(), record = try await service.compactDatabase(at: database, tool: .codex)
        XCTAssertEqual(record.state, .stored, record.message)
        try await service.restore(record.id)
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    func testSharedOllamaBlobsArePreservedAndExclusiveBlobsRestore() async throws {
        let a = "sha256-" + String(repeating: "a", count: 64), b = "sha256-" + String(repeating: "b", count: 64), c = "sha256-" + String(repeating: "c", count: 64)
        let shared = try file(".ollama/models/blobs/" + a, "shared")
        let exclusive = try file(".ollama/models/blobs/" + b, "exclusive")
        try file(".ollama/models/blobs/" + c, "other")
        let one = try file(".ollama/models/manifests/registry.ollama.ai/library/one/latest", "{\"config\":{\"digest\":\"sha256:\(String(repeating: "a", count: 64))\"},\"layers\":[{\"digest\":\"sha256:\(String(repeating: "b", count: 64))\"}]}")
        let two = try file(".ollama/models/manifests/registry.ollama.ai/library/two/latest", "{\"config\":{\"digest\":\"sha256:\(String(repeating: "a", count: 64))\"},\"layers\":[{\"digest\":\"sha256:\(String(repeating: "c", count: 64))\"}]}")
        let result = await scanner().scan()
        let item = try XCTUnwrap(result.items.first { $0.url == one })
        XCTAssertEqual(item.bytes, Int64(try Data(contentsOf: one).count + Data(contentsOf: exclusive).count))
        let service = store(), record = try await service.apply([item])
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertTrue(fm.fileExists(atPath: shared.path))
        XCTAssertTrue(fm.fileExists(atPath: two.path))
        XCTAssertFalse(fm.fileExists(atPath: exclusive.path))
        try await service.restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: one.path)); XCTAssertTrue(fm.fileExists(atPath: exclusive.path))
    }

    func testChangedModelReferenceAndBusyModelAreRetained() async throws {
        let hash = String(repeating: "a", count: 64)
        try file(".ollama/models/blobs/sha256-" + hash)
        let manifest = "{\"config\":{\"digest\":\"sha256:\(hash)\"},\"layers\":[]}"
        let one = try file(".ollama/models/manifests/registry.ollama.ai/library/one/latest", manifest)
        let items = (await scanner().scan()).items
        try file(".ollama/models/manifests/registry.ollama.ai/library/two/latest", manifest)
        do { _ = try await store().apply(items); XCTFail("changed shared references admitted") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: one.path))
        let busy = await scanner(activity: { [.ollama] }).scan()
        XCTAssertTrue(busy.items.isEmpty)
    }

    func testWorktreeRoundTripKeepsBranchesAndRepositoryConnection() async throws {
        let tree = try worktreeFixture()
        let result = await scanner().scan()
        let item = try XCTUnwrap(result.items.first { $0.kind == .worktree }, result.retained.map(\.reason).joined(separator: ";"))
        let service = store(), record = try await service.apply([item])
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertFalse(fm.fileExists(atPath: tree.path))
        let repo = home.appendingPathComponent("repo")
        XCTAssertTrue(try command("/usr/bin/git", ["-C", repo.path, "branch", "--list", "fixture"]).contains("fixture"))
        try await service.restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: tree.appendingPathComponent("tracked.txt").path))
        XCTAssertEqual(try command("/usr/bin/git", ["-C", tree.path, "status", "--porcelain"]).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
    func testDirtyLockedAndUnpushedWorktreesAreRetained() async throws {
        let tree = try worktreeFixture()
        try Data("untracked".utf8).write(to: tree.appendingPathComponent("untracked.txt"))
        let dirty = await scanner().scan()
        XCTAssertFalse(dirty.items.contains { $0.kind == .worktree })
        XCTAssertTrue(dirty.retained.contains { $0.reason.contains("改动") })
        try fm.removeItem(at: tree.appendingPathComponent("untracked.txt"))
        _ = try command("/usr/bin/git", ["-C", tree.path, "worktree", "lock", tree.path])
        let locked = await scanner().scan()
        XCTAssertFalse(locked.items.contains { $0.kind == .worktree })
    }
    func testBudgetAndCorruptHistoryFailClosed() async throws {
        try file(".claude/cache/one.bin"); try file(".claude/cache/two.bin")
        let limited = await scanner(maximum: 1).scan()
        XCTAssertTrue(limited.isPartial)
        let service = store(); _ = try await service.history()
        try Data("corrupt".utf8).write(to: recovery.appendingPathComponent("history.json"))
        do { _ = try await service.history(); XCTFail("corrupt history accepted") } catch {}
    }
    func testInterruptedRenameAndRestoreAreReconciledFromJournal() async throws {
        let cache = try file(".claude/cache/old.bin", "recover me")
        let scan = await scanner().scan(), service = store()
        let record = try await service.apply(scan.items)
        let journal = recovery.appendingPathComponent("history.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        raw[0]["state"] = "prepared"
        var paths = try XCTUnwrap(raw[0]["paths"] as? [[String: Any]])
        paths[0]["completed"] = false; paths[0].removeValue(forKey: "storedSignature")
        raw[0]["paths"] = paths
        try JSONSerialization.data(withJSONObject: raw).write(to: journal)
        let reopened = store(), reconciled = try await reopened.history()
        XCTAssertEqual(reconciled.first?.state, .partial)
        try await reopened.restore(record.id)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "recover me")
        // Model a crash immediately after rename back, before marking the restore step complete.
        var restoredRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        restoredRaw[0]["state"] = "restoring"
        var restoredPaths = try XCTUnwrap(restoredRaw[0]["paths"] as? [[String: Any]])
        restoredPaths[0]["completed"] = true; restoredRaw[0]["paths"] = restoredPaths
        try JSONSerialization.data(withJSONObject: restoredRaw).write(to: journal)
        try await store().restore(record.id)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "recover me")
    }

    func testInterruptedCodexRestoreResumesWithoutOverwritingNewState() async throws {
        let (session, database, _) = try codexFixture()
        let scan = await scanner().scan(sessionRetentionDays: 30)
        let selected = try XCTUnwrap(scan.items.first { $0.kind == .session })
        let service = store(), record = try await service.apply([selected])
        XCTAssertEqual(record.state, .stored, record.message)
        let journal = recovery.appendingPathComponent("history.json"), beforeRestore = try Data(contentsOf: journal)
        try await service.restore(record.id)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeRestore) as? [[String: Any]])
        raw[0]["state"] = "restoring"
        try JSONSerialization.data(withJSONObject: raw).write(to: journal)
        try await store().restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: session.path))
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM threads;").trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testInterruptedMoveDoesNotTrustModifiedRecoveryContent() async throws {
        let cache = try file(".claude/cache/old.bin", "original")
        let scan = await scanner().scan(), service = store()
        _ = try await service.apply(scan.items)
        let journal = recovery.appendingPathComponent("history.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        var paths = try XCTUnwrap(raw[0]["paths"] as? [[String: Any]])
        let storedURL = try XCTUnwrap((paths[0]["stored"] as? String).flatMap(URL.init(string:)))
        try Data("modified after interruption".utf8).write(to: storedURL)
        paths[0]["completed"] = false; paths[0].removeValue(forKey: "storedSignature")
        raw[0]["state"] = "prepared"; raw[0]["paths"] = paths
        try JSONSerialization.data(withJSONObject: raw).write(to: journal)
        do { _ = try await store().history(); XCTFail("modified recovery was trusted") } catch {}
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
    }
    func testPersonalCLIProgramRoundTripRetainsSettingsAndSessions() async throws {
        let program = try file(".local/bin/codex", "fixture executable")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let setting = try file(".codex/config.toml", "preserve settings")
        let session = try file(".codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-" + sessionID + ".jsonl")
        let scan = await scanner().scan(), item = try XCTUnwrap(scan.items.first { $0.kind == .tool })
        let service = store(), record = try await service.apply([item])
        XCTAssertEqual(record.state, .stored)
        XCTAssertFalse(fm.fileExists(atPath: program.path))
        XCTAssertTrue(fm.fileExists(atPath: setting.path)); XCTAssertTrue(fm.fileExists(atPath: session.path))
        try await service.restore(record.id)
        XCTAssertEqual(try String(contentsOf: program, encoding: .utf8), "fixture executable")
        XCTAssertEqual((try fm.attributesOfItem(atPath: program.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testPersonalCLILinkMovesOnlyEntryAndLeavesTargetUntouched() async throws {
        let target = try file("outside/package/bin/codex", "package remains")
        let entry = home.appendingPathComponent(".local/bin/codex")
        try fm.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: entry, withDestinationURL: target)
        let stamp = timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0)
        var times = [stamp, stamp]
        XCTAssertEqual(lutimes(entry.path, &times), 0)
        let scan = await scanner().scan(), item = try XCTUnwrap(scan.items.first { $0.kind == .tool })
        XCTAssertEqual(item.bytes, 0)
        XCTAssertTrue(item.detail.contains("命令入口"))
        let service = store(), record = try await service.apply([item])
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertFalse(fm.fileExists(atPath: entry.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "package remains")
        try await service.restore(record.id)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: entry.path), target.path)
    }

    func testSuccessiveCodexCleanupBatchesRestoreInReverseOrder() async throws {
        let (firstSession, database, index) = try codexFixture()
        let secondID = "87654321-4321-4321-8321-cba987654321"
        let secondSession = try file(".codex/archived_sessions/rollout-2026-01-01T00-00-00-" + secondID + ".jsonl")
        try sqlite(database, "INSERT INTO threads VALUES ('\(secondID)','\(secondSession.path)');")
        let line = "{\"id\":\"\(secondID)\",\"thread_name\":\"Fixture Two\"}\n"
        let indexFile = try FileHandle(forWritingTo: index); try indexFile.seekToEnd(); try indexFile.write(contentsOf: Data(line.utf8)); try indexFile.close()
        let scanOne = await scanner().scan(sessionRetentionDays: 30)
        let one = try XCTUnwrap(scanOne.items.first { $0.url == firstSession })
        let service = store(), recordOne = try await service.apply([one])
        XCTAssertEqual(recordOne.state, .stored, recordOne.message)
        let scanTwo = await scanner().scan(sessionRetentionDays: 30)
        let two = try XCTUnwrap(scanTwo.items.first { $0.url == secondSession })
        let recordTwo = try await service.apply([two])
        XCTAssertEqual(recordTwo.state, .stored, recordTwo.message)
        try await service.restore(recordTwo.id)
        try await service.restore(recordOne.id)
        XCTAssertTrue(fm.fileExists(atPath: firstSession.path)); XCTAssertTrue(fm.fileExists(atPath: secondSession.path))
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM threads;").trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testCancelledCleanupDoesNotMoveSelectedFiles() async throws {
        let cache = try file(".claude/cache/old.bin"), scan = await scanner().scan()
        let service = store()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.apply(scan.items)
        }
        do { _ = try await operation.value; XCTFail("cancelled cleanup proceeded") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
        let history = try await service.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testSharedModelDependenciesMustExistBeforeRestoration() async throws {
        let hash = String(repeating: "a", count: 64)
        let blob = try file(".ollama/models/blobs/sha256-" + hash)
        let manifest = "{\"config\":{\"digest\":\"sha256:\(hash)\"},\"layers\":[]}"
        let one = try file(".ollama/models/manifests/registry.ollama.ai/library/one/latest", manifest)
        let two = try file(".ollama/models/manifests/registry.ollama.ai/library/two/latest", manifest)
        let firstScan = await scanner().scan(), service = store()
        let recordOne = try await service.apply([XCTUnwrap(firstScan.items.first { $0.url == one })])
        let secondScan = await scanner().scan()
        let recordTwo = try await service.apply([XCTUnwrap(secondScan.items.first { $0.url == two })])
        XCTAssertFalse(fm.fileExists(atPath: blob.path))
        do { try await service.restore(recordOne.id); XCTFail("manifest restored without shared dependency") } catch {}
        try await service.restore(recordTwo.id)
        try await service.restore(recordOne.id)
        XCTAssertTrue(fm.fileExists(atPath: one.path)); XCTAssertTrue(fm.fileExists(atPath: two.path)); XCTAssertTrue(fm.fileExists(atPath: blob.path))
    }

    func testCursorNativeSessionsHaveUniqueIDsAndRemoveOnlyOwnedRows() async throws {
        let database = try cursorFixture()
        let second = "87654321-4321-4321-8321-cba987654321"
        try addCursorSession(database, id: second)
        let scan = await scanner().scan(sessionRetentionDays: 30)
        let sessions = scan.items.filter { $0.kind == .databaseSession }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.id)).count, 2)
        let selected = try XCTUnwrap(sessions.first { $0.conversationID == sessionID })
        XCTAssertTrue(selected.detail.contains("共享"))
        let service = store(), record = try await service.apply([selected])
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM composerHeaders;").trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM cursorDiskKV WHERE key='composerData:\(sessionID)' OR key GLOB 'bubbleId:\(sessionID):*';").trimmingCharacters(in: .whitespacesAndNewlines), "0")
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM cursorDiskKV WHERE key='composerData:\(second)';").trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM cursorDiskKV WHERE key GLOB 'agentKv:blob:*' OR key GLOB 'inlineDiff:*';").trimmingCharacters(in: .whitespacesAndNewlines), "2")
        XCTAssertEqual(try sqlite(database, "SELECT value FROM ItemTable WHERE key='secret:fixture';").trimmingCharacters(in: .whitespacesAndNewlines), "fixture-only")
        try await service.restore(record.id)
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM composerHeaders;").trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testCursorRelatedSessionsRequireCompleteSelection() async throws {
        let database = try cursorFixture(), child = "87654321-4321-4321-8321-cba987654321"
        try addCursorSession(database, id: child, parent: sessionID)
        try sqlite(database, "UPDATE cursorDiskKV SET value=json_set(CAST(value AS TEXT),'$.subagentComposerIds',json('[\"\(child)\"]')) WHERE key='composerData:\(sessionID)';")
        let scan = await scanner().scan(sessionRetentionDays: 30)
        let sessions = scan.items.filter { $0.kind == .databaseSession }
        XCTAssertEqual(sessions.count, 2)
        let parent = try XCTUnwrap(sessions.first { $0.conversationID == sessionID })
        do { _ = try await store().apply([parent]); XCTFail("referenced child was left behind") } catch {}
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM composerHeaders;").trimmingCharacters(in: .whitespacesAndNewlines), "2")
        let record = try await store().apply(sessions)
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM composerHeaders;").trimmingCharacters(in: .whitespacesAndNewlines), "0")
        try await store().restore(record.id)
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM composerHeaders;").trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testCursorUnknownSchemaDraftActiveAndLegacyIndexesAreRetained() async throws {
        let database = try cursorFixture()
        let defaultRetention = await scanner().scan(sessionRetentionDays: 0)
        XCTAssertFalse(defaultRetention.items.contains { $0.kind == .databaseSession })
        let active = await scanner(activity: { [.cursor] }).scan(sessionRetentionDays: 30)
        XCTAssertFalse(active.items.contains { $0.kind == .databaseSession })
        try sqlite(database, "UPDATE cursorDiskKV SET value=json_set(CAST(value AS TEXT),'$.isDraft',json('true')) WHERE key='composerData:\(sessionID)';")
        let draft = await scanner().scan(sessionRetentionDays: 30)
        XCTAssertFalse(draft.items.contains { $0.kind == .databaseSession })
        try sqlite(database, "UPDATE cursorDiskKV SET value=json_set(CAST(value AS TEXT),'$.isDraft',json('false'),'$._v',999) WHERE key='composerData:\(sessionID)';")
        let unknown = await scanner().scan(sessionRetentionDays: 30)
        XCTAssertFalse(unknown.items.contains { $0.kind == .databaseSession })
        XCTAssertTrue(unknown.isPartial)
        try sqlite(database, "UPDATE cursorDiskKV SET value=json_set(CAST(value AS TEXT),'$._v',16) WHERE key='composerData:\(sessionID)';")
        let legacy = try file("Library/Application Support/Cursor/User/workspaceStorage/workspace/state.vscdb", "", old: false)
        try sqlite(legacy, "CREATE TABLE ItemTable(key TEXT,value BLOB); INSERT INTO ItemTable VALUES('composer.composerData','{\"allComposers\":[]}');")
        let oldIndex = await scanner().scan(sessionRetentionDays: 30)
        XCTAssertFalse(oldIndex.items.contains { $0.kind == .databaseSession })
        XCTAssertTrue(oldIndex.retained.contains { $0.reason.contains("旧版工作区") })
    }

    func testCursorRestoreRejectsSubsequentUserDataAndInterruptedRestoreResumes() async throws {
        let database = try cursorFixture(), service = store()
        let scan = await scanner().scan(sessionRetentionDays: 30)
        let selected = try XCTUnwrap(scan.items.first { $0.kind == .databaseSession })
        let record = try await service.apply([selected])
        XCTAssertEqual(record.state, .stored, record.message)
        let journal = recovery.appendingPathComponent("history.json"), beforeRestore = try Data(contentsOf: journal)
        try await service.restore(record.id)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeRestore) as? [[String: Any]])
        raw[0]["state"] = "restoring"
        try JSONSerialization.data(withJSONObject: raw).write(to: journal)
        try await store().restore(record.id)
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM composerHeaders;").trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let secondScan = await scanner().scan(sessionRetentionDays: 30)
        let next = try XCTUnwrap(secondScan.items.first { $0.kind == .databaseSession })
        let another = try await service.apply([next])
        try sqlite(database, "INSERT INTO ItemTable VALUES ('new-user-setting','preserve new value');")
        do { try await service.restore(another.id); XCTFail("subsequent user data overwritten") } catch {}
        XCTAssertEqual(try sqlite(database, "SELECT value FROM ItemTable WHERE key='new-user-setting';").trimmingCharacters(in: .whitespacesAndNewlines), "preserve new value")
    }

    func testCodexOrphanImagesRequireAllIndexesToBeAbsentAndOnlyMoveTheImage() async throws {
        _ = try codexVisualizationFixture()
        let image = try file(".codex/visualizations/2026/01/01/\(sessionID)/assets/chart.png", "fake raster fixture")
        let html = try file(".codex/visualizations/2026/01/01/\(sessionID)/index.html", "keep HTML")
        let attached = try file(".codex/attachments/\(sessionID)/keep.png")
        let nestedAttachment = try file(".codex/visualizations/2026/01/01/\(sessionID)/attachments/keep.png")
        let scan = await scanner().scan()
        let candidates = scan.items.filter { $0.kind == .orphanedVisualization }
        XCTAssertEqual(candidates.map(\.url), [image])
        XCTAssertEqual(candidates.first?.conversationID, sessionID)
        let service = store(), record = try await service.apply(candidates)
        XCTAssertEqual(record.state, .stored, record.message)
        XCTAssertFalse(fm.fileExists(atPath: image.path))
        XCTAssertTrue(fm.fileExists(atPath: html.path)); XCTAssertTrue(fm.fileExists(atPath: attached.path)); XCTAssertTrue(fm.fileExists(atPath: nestedAttachment.path))
        try await service.restore(record.id)
        XCTAssertEqual(try String(contentsOf: image, encoding: .utf8), "fake raster fixture")
    }

    func testCodexImagesWithDatabaseIndexRolloutOrSharedAttachmentReferencesAreRetained() async throws {
        let database = try codexVisualizationFixture()
        let idTwo = "87654321-4321-4321-8321-cba987654321", idThree = "aaaaaaaa-1234-4234-8234-123456789abc", idFour = "bbbbbbbb-1234-4234-8234-123456789abc"
        let one = try file(".codex/visualizations/2026/01/01/\(sessionID)/one.png")
        let two = try file(".codex/visualizations/2026/01/01/\(idTwo)/two.png")
        let three = try file(".codex/visualizations/2026/01/01/\(idThree)/three.png")
        let four = try file(".codex/visualizations/2026/01/01/\(idFour)/four.png")
        try sqlite(database, "INSERT INTO threads VALUES('\(sessionID)','/fixture/rollout');")
        try file(".codex/session_index.jsonl", "{\"id\":\"\(idTwo)\"}\n")
        try file(".codex/archived_sessions/rollout-2026-01-01T00-00-00-\(idThree).jsonl")
        let payload = try String(data: JSONSerialization.data(withJSONObject: ["root": four.path]), encoding: .utf8).map(quote)
        try sqlite(database, "INSERT INTO thread_attachments VALUES('attachment','\(sessionID)','worktree','fixture',\(payload ?? "'{}'"),0);")
        let scan = await scanner().scan()
        XCTAssertFalse(scan.items.contains { $0.kind == .orphanedVisualization })
        XCTAssertTrue([one,two,three,four].allSatisfy { fm.fileExists(atPath: $0.path) })
    }

    func testCodexImageReappearingReferenceAndUnknownIndexAreRejected() async throws {
        let database = try codexVisualizationFixture()
        let image = try file(".codex/visualizations/2026/01/01/\(sessionID)/one.jpg")
        let scan = await scanner().scan(), candidate = try XCTUnwrap(scan.items.first { $0.kind == .orphanedVisualization })
        try sqlite(database, "INSERT INTO threads VALUES('\(sessionID)','/fixture/returned');")
        do { _ = try await store().apply([candidate]); XCTFail("new association ignored") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: image.path))
        try sqlite(database, "DELETE FROM threads;")
        try file(".codex/session_index.jsonl", "unknown index format")
        let corrupt = await scanner().scan()
        XCTAssertFalse(corrupt.items.contains { $0.kind == .orphanedVisualization })
        XCTAssertTrue(corrupt.isPartial)
        let busy = await scanner(activity: { [.codex] }).scan()
        XCTAssertFalse(busy.items.contains { $0.kind == .orphanedVisualization })
    }

    func testCodexImageRecoveryHandlesInterruptedMoveAndRefusesOverwrite() async throws {
        _ = try codexVisualizationFixture()
        let image = try file(".codex/visualizations/2026/01/01/\(sessionID)/one.png")
        let scan = await scanner().scan(), item = try XCTUnwrap(scan.items.first { $0.kind == .orphanedVisualization })
        let service = store(), record = try await service.apply([item])
        let journal = recovery.appendingPathComponent("history.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        raw[0]["state"] = "prepared"
        var paths = try XCTUnwrap(raw[0]["paths"] as? [[String: Any]])
        paths[0]["completed"] = false; paths[0].removeValue(forKey: "storedSignature"); raw[0]["paths"] = paths
        try JSONSerialization.data(withJSONObject: raw).write(to: journal)
        try await store().restore(record.id)
        XCTAssertTrue(fm.fileExists(atPath: image.path))
        let nextScan = await scanner().scan(), next = try XCTUnwrap(nextScan.items.first { $0.kind == .orphanedVisualization })
        let second = try await service.apply([next])
        try Data("new file".utf8).write(to: image)
        do { try await service.restore(second.id); XCTFail("new image overwritten") } catch {}
        XCTAssertEqual(try String(contentsOf: image, encoding: .utf8), "new file")
    }

    func testCursorCleanupCompactsDeletedRowsInsideTheStagedCopy() async throws {
        let database = try cursorFixture()
        try sqlite(database, "UPDATE cursorDiskKV SET value=zeroblob(400000) WHERE key GLOB 'bubbleId:*';")
        let before = (try fm.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.int64Value ?? 0
        let scan = await scanner().scan(sessionRetentionDays: 30), item = try XCTUnwrap(scan.items.first { $0.kind == .databaseSession })
        let record = try await store().apply([item])
        XCTAssertEqual(record.state, .stored, record.message)
        let after = (try fm.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertLessThan(after, before)
        try await store().restore(record.id)
        XCTAssertEqual(try sqlite(database, "SELECT length(value) FROM cursorDiskKV WHERE key GLOB 'bubbleId:*';").trimmingCharacters(in: .whitespacesAndNewlines), "400000")
    }

    func testCursorRelationsExposeReviewIDsAndHeldDraftKeepsItsParent() async throws {
        let database = try cursorFixture(), child = "87654321-4321-4321-8321-cba987654321"
        try addCursorSession(database, id: child, parent: sessionID)
        let first = await scanner().scan(sessionRetentionDays: 30)
        let parent = try XCTUnwrap(first.items.first { $0.kind == .databaseSession && $0.conversationID == sessionID })
        XCTAssertEqual(parent.relatedConversationIDs, [child])
        try sqlite(database, "UPDATE cursorDiskKV SET value=json_set(CAST(value AS TEXT),'$.isDraft',json('true')) WHERE key='composerData:\(child)';")
        let held = await scanner().scan(sessionRetentionDays: 30)
        XCTAssertFalse(held.items.contains { $0.kind == .databaseSession })
        XCTAssertTrue(held.retained.contains { $0.conversationID == sessionID && $0.reason.contains("关联") })
        XCTAssertEqual(Set(held.retained.map(\.id)).count, held.retained.count)
    }

    func testCodexRecentInvalidDateAndUnknownAttachmentSchemaImagesStayUntouched() async throws {
        let database = try codexVisualizationFixture()
        let recent = try file(".codex/visualizations/2026/01/01/\(sessionID)/recent.png", old: false)
        let invalidDate = try file(".codex/visualizations/2026/02/31/\(sessionID)/invalid.png")
        let scan = await scanner().scan()
        XCTAssertFalse(scan.items.contains { $0.kind == .orphanedVisualization })
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: recent.path)
        try sqlite(database, "ALTER TABLE thread_attachments ADD COLUMN unknown_reference TEXT;")
        let unknown = await scanner().scan()
        XCTAssertFalse(unknown.items.contains { $0.kind == .orphanedVisualization })
        XCTAssertTrue(unknown.isPartial)
        XCTAssertTrue(fm.fileExists(atPath: recent.path)); XCTAssertTrue(fm.fileExists(atPath: invalidDate.path))
    }

    func testCursorDatabaseReplacementCanRecoverBeforeFinalJournalStateWasWritten() async throws {
        let database = try cursorFixture(), scan = await scanner().scan(sessionRetentionDays: 30)
        let candidate = try XCTUnwrap(scan.items.first { $0.kind == .databaseSession })
        let record = try await store().apply([candidate])
        XCTAssertEqual(record.state, .stored, record.message)
        let journal = recovery.appendingPathComponent("history.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        raw[0]["state"] = "prepared"
        // The before/after logical content guards were persisted before atomic replacement.
        XCTAssertNotNil((raw[0]["replacementGuards"] as? [String: String])?[database.path])
        XCTAssertNotNil((raw[0]["originalGuards"] as? [String: String])?[database.path])
        try JSONSerialization.data(withJSONObject: raw).write(to: journal)
        try await store().restore(record.id)
        XCTAssertEqual(try sqlite(database, "SELECT count(*) FROM composerHeaders;").trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testLegacyRecoveryRecordWithoutNewCandidateKeysDecodesAndRestores() async throws {
        let cache = try file(".claude/cache/legacy.bin", "legacy recovery fixture")
        let scan = await scanner().scan(), service = store()
        let record = try await service.apply(scan.items)
        let journal = recovery.appendingPathComponent("history.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        var items = try XCTUnwrap(raw[0]["items"] as? [[String: Any]])
        for index in items.indices {
            XCTAssertNil(items[index]["relatedConversationIDs"])
            for key in ["dependencies", "cursorSession", "orphanedThreadID", "conversationID", "relatedConversationIDs"] { items[index].removeValue(forKey: key) }
        }
        raw[0]["items"] = items
        let legacy = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode([AIRecoveryRecord].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].items[0].relatedConversationIDs, [])
        XCTAssertNil(decoded[0].items[0].conversationID)
        try legacy.write(to: journal)
        let reopened = store(), history = try await reopened.history()
        XCTAssertEqual(history.first?.id, record.id)
        try await reopened.restore(record.id)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "legacy recovery fixture")
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    private func cursorFixture() throws -> URL {
        let database = try file("Library/Application Support/Cursor/User/globalStorage/state.vscdb", "", old: false)
        try sqlite(database, """
            CREATE TABLE ItemTable(key TEXT UNIQUE ON CONFLICT REPLACE,value BLOB);
            CREATE TABLE cursorDiskKV(key TEXT UNIQUE ON CONFLICT REPLACE,value BLOB);
            CREATE TABLE composerHeaders(composerId TEXT PRIMARY KEY,workspaceId TEXT,createdAt INTEGER,lastUpdatedAt INTEGER,isArchived INTEGER,isSubagent INTEGER,recency INTEGER,checkpointAt INTEGER,value TEXT,subagentTypeName TEXT);
            INSERT INTO ItemTable VALUES('secret:fixture','fixture-only');
            INSERT INTO cursorDiskKV VALUES('agentKv:blob:shared-fixture','shared content fixture');
            INSERT INTO cursorDiskKV VALUES('inlineDiff:workspace:shared-fixture','independent editor fixture');
            """)
        try addCursorSession(database, id: sessionID)
        return database
    }
    private func addCursorSession(_ database: URL, id: String, parent: String? = nil) throws {
        let stamp = Int64(old.timeIntervalSince1970 * 1000)
        var object: [String: Any] = ["composerId": id, "_v": 16, "createdAt": stamp, "lastUpdatedAt": stamp, "status": "completed", "isDraft": false, "isProject": false, "subComposerIds": [], "subagentComposerIds": [], "text": "isolated fixture only", "conversationState": "fixture opaque state"]
        if let parent { object["subagentInfo"] = ["parentComposerId": parent] }
        let value = String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        try sqlite(database, "INSERT INTO composerHeaders VALUES(\(quote(id)),'workspace',\(stamp),\(stamp),0,0,0,0,'{}',NULL); INSERT INTO cursorDiskKV VALUES(\(quote("composerData:" + id)),\(quote(value))); INSERT INTO cursorDiskKV VALUES(\(quote("bubbleId:" + id + ":aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")),'isolated message body');")
    }
    private func codexVisualizationFixture() throws -> URL {
        let database = try file(".codex/state_5.sqlite", "", old: false)
        try sqlite(database, "CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT NOT NULL); CREATE TABLE thread_attachments(id TEXT PRIMARY KEY,thread_id TEXT NOT NULL,attachment_type TEXT NOT NULL,identity_key TEXT NOT NULL,payload TEXT NOT NULL,created_at INTEGER NOT NULL);")
        return database
    }

    private func worktreeFixture() throws -> URL {
        let repo = home.appendingPathComponent("repo"), tree = home.appendingPathComponent(".codex/worktrees/fixture")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try command("/usr/bin/git", ["init", repo.path])
        try Data("fixture".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        _ = try command("/usr/bin/git", ["-C", repo.path, "add", "tracked.txt"])
        _ = try command("/usr/bin/git", ["-C", repo.path, "-c", "user.name=Orbit Fixture", "-c", "user.email=fixture@localhost", "commit", "-m", "fixture"])
        _ = try command("/usr/bin/git", ["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        try fm.createDirectory(at: tree.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try command("/usr/bin/git", ["-C", repo.path, "worktree", "add", "-b", "fixture", tree.path])
        if let iterator = fm.enumerator(at: tree, includingPropertiesForKeys: nil) {
            for case let child as URL in iterator { try fm.setAttributes([.modificationDate: old], ofItemAtPath: child.path) }
        }
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: tree.path)
        return tree
    }
}
