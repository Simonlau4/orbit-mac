import XCTest
import Darwin
@testable import OrbitCore

final class MaintenanceEngineTests: XCTestCase {
    private var root: URL!
    private var engine: MaintenanceEngine!
    override func setUpWithError() throws {
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-maintenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = MaintenanceEngine(home: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    @discardableResult private func file(_ path: String, _ data: Data = Data([0xff, 0x00, 0xfe])) throws -> URL {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u); return u
    }
    private func plist(_ path: String, _ object: [String: Any]) throws -> URL {
        try file(path, PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))
    }
    @discardableResult private func sql(_ path: String, _ statement: String) async throws -> String {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/sqlite3", arguments: [u.path, statement], timeoutSeconds: 10))
        XCTAssertEqual(result.exitCode, 0, result.output)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func executeAll(_ plan: MaintenancePlan) async -> MaintenanceResult { await engine.execute(plan, selectedIDs: Set(plan.candidates.map(\.id)), runningBundleIDs: []) }

    func testAllSeventeenMoleMaintenanceEntriesAreRepresentedAndRootCommandsAreFixed() {
        XCTAssertEqual(MaintenanceTask.allCases.count, 19) // Mole's 17 plus the separate DNS cache and system DNS actions.
        XCTAssertTrue(MaintenanceTask.repairDiskPermissions.requiresAdmin)
        XCTAssertEqual(MaintenanceService.command(for: .rebuildQuickLook).arguments, ["-r"])
        XCTAssertTrue(MaintenanceService.command(for: .repairDiskPermissions).arguments[1].contains("resetUserPermissions / \(getuid())"))
        for task in MaintenanceTask.allCases where !task.usesCommand && task != .auditLoginItems {
            XCTAssertEqual(MaintenanceService.command(for: task).executable, "/usr/bin/false")
        }
    }
    func testBrokenPreferencesArePreviewedMovedAndRestoredWithoutTouchingAppleOrValidPlists() async throws {
        let broken = try file("Library/Preferences/org.example.broken.plist")
        let apple = try file("Library/Preferences/com.apple.fixture.plist")
        let valid = try plist("Library/Preferences/org.example.valid.plist", ["value": 1])
        let array = try file("Library/Preferences/org.example.array.plist", PropertyListSerialization.data(fromPropertyList: ["valid", "array"], format: .binary, options: 0))
        let plan = await engine.preview(.repairBrokenPlists, runningBundleIDs: [])
        XCTAssertEqual(plan.candidates.map(\.url), [broken])
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
        let result = await executeAll(plan)
        XCTAssertEqual(result.status, .success, result.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: apple.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: array.path))
        let history = try await engine.history()
        try await engine.restore(XCTUnwrap(history.first?.id))
        XCTAssertEqual(try Data(contentsOf: broken), Data([0xff, 0x00, 0xfe]))
        let restored = try await engine.history()
        XCTAssertTrue(try XCTUnwrap(restored.first).isRestored)
    }
    func testSavedStateAgeRunningAppAndMutationRace() async throws {
        let old = url("Library/Saved Application State/org.example.old.savedState")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let data = try file("Library/Saved Application State/org.example.old.savedState/state.data")
        let date = Date().addingTimeInterval(-40 * 86400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: data.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: old.path)
        let running = await engine.preview(.cleanSavedState, runningBundleIDs: ["org.example.old"])
        XCTAssertTrue(running.candidates.isEmpty)
        let plan = await engine.preview(.cleanSavedState, runningBundleIDs: [])
        XCTAssertEqual(plan.candidates.count, 1)
        try Data("changed".utf8).write(to: data)
        let changed = await executeAll(plan)
        XCTAssertEqual(changed.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
    }
    func testAllLegacyOverridesRestoreInReverseOrderAndKeepOtherPreferences() async throws {
        let p = try plist("Library/Preferences/com.apple.frameworks.diskimages.plist", ["skip-verify": true, "skip-verify-remote": true, "unrelated": "keep"])
        let plan = await engine.preview(.auditLegacyOverrides, runningBundleIDs: [])
        XCTAssertEqual(plan.candidates.count, 1)
        let result = await executeAll(plan)
        XCTAssertEqual(result.status, .success, result.message)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: p), format: nil) as? [String: Any])
        XCTAssertNil(values["skip-verify"]); XCTAssertNil(values["skip-verify-remote"]); XCTAssertEqual(values["unrelated"] as? String, "keep")
        let records = try await engine.history()
        try await engine.restore(XCTUnwrap(records.first?.id))
        let restored = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: p), format: nil) as? [String: Any])
        XCTAssertEqual(restored["skip-verify"] as? Bool, true); XCTAssertEqual(restored["skip-verify-remote"] as? Bool, true)
    }
    func testSpotlightPrunesOnlyMissingThirdPartyRulesAndRestores() async throws {
        let original = ["com.apple.system", "System.iphoneApps", "org.example.installed", "org.example.gone", "unrecognized"]
        let p = try plist("Library/Preferences/com.apple.spotlight.plist", ["EnabledPreferenceRules": original, "other": 4])
        let plan = await engine.preview(.pruneSpotlightOrphanRules, installedBundleIDs: ["org.example.installed"], runningBundleIDs: [])
        XCTAssertEqual(plan.candidates.count, 1)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success, result.message)
        let current = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: p), format: nil) as? [String: Any])
        XCTAssertEqual(current["EnabledPreferenceRules"] as? [String], original.filter { $0 != "org.example.gone" })
        let history = try await engine.history(); try await engine.restore(XCTUnwrap(history.first?.id))
        let restored = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: p), format: nil) as? [String: Any])
        XCTAssertEqual(restored["EnabledPreferenceRules"] as? [String], original)
    }
    func testQuarantineDatabaseRealBackupPruneAndRestore() async throws {
        let path = "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        try await sql(path, "CREATE TABLE LSQuarantineEvent(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO LSQuarantineEvent(name) VALUES('one'),('two');")
        let plan = await engine.preview(.cleanQuarantineEvents)
        XCTAssertEqual(plan.candidates.count, 1)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success, result.message)
        let count = try await sql(path, "SELECT COUNT(*) FROM LSQuarantineEvent;"); XCTAssertEqual(count, "0")
        let history = try await engine.history(); try await engine.restore(XCTUnwrap(history.first?.id))
        let restored = try await sql(path, "SELECT COUNT(*) FROM LSQuarantineEvent;"); XCTAssertEqual(restored, "2")
    }
    func testNotificationPruneKeepsRecentAndRestores() async throws {
        let path = "Library/Group Containers/group.com.apple.usernoted/db2/db"
        try await sql(path, "CREATE TABLE record(id INTEGER PRIMARY KEY, delivered_date INTEGER); INSERT INTO record VALUES(1,strftime('%s','now','-40 days')-978307200),(2,strftime('%s','now')-978307200); ")
        let plan = await engine.preview(.pruneNotificationDB)
        XCTAssertEqual(plan.candidates.count, 1)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success, result.message)
        let count = try await sql(path, "SELECT COUNT(*) FROM record;"); XCTAssertEqual(count, "1")
        let recent = try await sql(path, "SELECT id FROM record;"); XCTAssertEqual(recent, "2")
        let history = try await engine.history(); try await engine.restore(XCTUnwrap(history.first?.id))
        let restored = try await sql(path, "SELECT COUNT(*) FROM record;"); XCTAssertEqual(restored, "2")
    }
    func testNotificationDateSchemaChangeOrMixedTextValuesAreRetained() async throws {
        let path = "Library/Group Containers/group.com.apple.usernoted/db2/db"
        try await sql(path, "CREATE TABLE record(id INTEGER PRIMARY KEY, delivered_date); INSERT INTO record VALUES(1,strftime('%s','now','-40 days')-978307200),(2,'2026-10-26T12:00:00Z');")
        let plan = await engine.preview(.pruneNotificationDB)
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("数值格式") })
        let unchanged = try await sql(path, "SELECT COUNT(*) FROM record;"); XCTAssertEqual(unchanged, "2")
    }
    func testVacuumPreservesMessagesRowsAndRejectsSubsequentChangesOnRestore() async throws {
        let path = "Library/Messages/chat.db"
        try await sql(path, "CREATE TABLE message(id INTEGER PRIMARY KEY, payload BLOB); WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000) INSERT INTO message SELECT x,randomblob(1000) FROM n; DELETE FROM message WHERE id>2;")
        let plan = await engine.preview(.vacuumSQLiteDatabases, runningBundleIDs: [])
        XCTAssertEqual(plan.candidates.count, 1)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success, result.message)
        let rows = try await sql(path, "SELECT COUNT(*) FROM message;"); XCTAssertEqual(rows, "2")
        let free = try await sql(path, "PRAGMA freelist_count;"); XCTAssertEqual(free, "0")
        let history = try await engine.history()
        try await sql(path, "INSERT INTO message VALUES(3,'new');")
        do { try await engine.restore(XCTUnwrap(history.first?.id)); XCTFail("must not overwrite new messages") } catch {}
        let current = try await sql(path, "SELECT COUNT(*) FROM message;"); XCTAssertEqual(current, "3")
    }
    func testSharedFileListPreservesRecentDocumentsAndValidLists() async throws {
        let broken = try file("Library/Application Support/com.apple.sharedfilelist/broken.sfl3")
        _ = try file("Library/Application Support/com.apple.sharedfilelist/ApplicationRecentDocuments/data.sfl3")
        _ = try plist("Library/Application Support/com.apple.sharedfilelist/valid.sfl3", ["items": []])
        let plan = await engine.preview(.repairSharedFileLists)
        XCTAssertEqual(plan.candidates.map(\.url), [broken])
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success)
    }
    func testLaunchAgentAuditKeepsProtectedAndExternalPrograms() async throws {
        let broken = try plist("Library/LaunchAgents/org.example.gone.plist", ["Label": "org.example.gone", "Program": "/Applications/OrbitMissingFixture.app/Contents/MacOS/fixture"])
        _ = try plist("Library/LaunchAgents/org.example.vpn.plist", ["Label": "org.example.vpn", "Program": "/missing-protected"])
        _ = try plist("Library/LaunchAgents/org.example.external.plist", ["Label": "org.example.external", "Program": "/Volumes/Unplugged/fixture"])
        let plan = await engine.preview(.cleanBrokenLaunchAgents)
        XCTAssertEqual(plan.candidates.map(\.url), [broken])
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success, result.message)
        let history = try await engine.history(); try await engine.restore(XCTUnwrap(history.first?.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }
    func testBrokenAppLinkIsRestoredAsLinkAndArbitraryLinkIsKept() async throws {
        let bin = url(".local/bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let appLink = bin.appendingPathComponent("example")
        try FileManager.default.createSymbolicLink(atPath: appLink.path, withDestinationPath: "/Applications/OrbitMissingFixture.app/Contents/MacOS/example")
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("private").path, withDestinationPath: "/etc/missing-fixture")
        let plan = await engine.preview(.auditBrokenCommandLinks)
        XCTAssertEqual(plan.candidates.map(\.url), [appLink])
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success, result.message)
        let history = try await engine.history(); try await engine.restore(XCTUnwrap(history.first?.id))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: appLink.path), "/Applications/OrbitMissingFixture.app/Contents/MacOS/example")
    }
    func testRestoreConflictAndCorruptJournalFailClosed() async throws {
        let p = try file("Library/Preferences/org.example.broken.plist")
        let plan = await engine.preview(.repairBrokenPlists)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success)
        let history = try await engine.history()
        try Data("new-content".utf8).write(to: p)
        do { try await engine.restore(XCTUnwrap(history.first?.id)); XCTFail("conflict") } catch {}
        XCTAssertEqual(try Data(contentsOf: p), Data("new-content".utf8))
        let journal = url("Library/Application Support/Orbit/MaintenanceRecovery/history.json")
        try Data("corrupt".utf8).write(to: journal)
        do { _ = try await engine.history(); XCTFail("damaged history") } catch {}
    }
    func testSymlinkRootAndPostScanRunningApplicationAreKept() async throws {
        let p = try file("Library/Preferences/org.example.broken.plist")
        let plan = await engine.preview(.repairBrokenPlists)
        let running = await engine.execute(plan, selectedIDs: Set(plan.candidates.map(\.id)), runningBundleIDs: ["org.example.broken"])
        XCTAssertEqual(running.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.path))
        let outside = try file("outside")
        try FileManager.default.removeItem(at: p)
        try FileManager.default.createSymbolicLink(at: p, withDestinationURL: outside)
        let protected = await engine.preview(.repairBrokenPlists)
        XCTAssertTrue(protected.candidates.isEmpty)
    }
    private func writeHistory(_ records: [MaintenanceRecoveryRecord]) throws {
        try JSONEncoder().encode(records).write(to: url("Library/Application Support/Orbit/MaintenanceRecovery/history.json"), options: .atomic)
    }
    func testInterruptedFileRestoreReconcilesAlreadyRestoredPath() async throws {
        let p = try file("Library/Preferences/org.example.broken.plist")
        let plan = await engine.preview(.repairBrokenPlists)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success)
        var records = try await engine.history()
        records[0].entries[0].restoring = true
        records[0].entries[0].restorationFingerprint = records[0].entries[0].candidate.fingerprint
        try writeHistory(records)
        try FileManager.default.moveItem(at: records[0].entries[0].backup, to: p)
        try await engine.restore(records[0].id)
        let recovered = try await engine.history()
        XCTAssertTrue(recovered[0].isRestored)
    }
    func testInterruptedPreferenceApplyCanRestoreFromExpectedPlist() async throws {
        let p = try plist("Library/Preferences/.GlobalPreferences.plist", ["NSAppSleepDisabled": true, "unchanged": 4])
        let plan = await engine.preview(.auditLegacyOverrides)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success)
        var records = try await engine.history()
        records[0].entries[0].afterFingerprint = nil
        records[0].entries[0].completed = false
        try writeHistory(records)
        try await engine.restore(records[0].id)
        let restored = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: p), format: nil) as? [String: Any])
        XCTAssertEqual(restored["NSAppSleepDisabled"] as? Bool, true)
        XCTAssertEqual(restored["unchanged"] as? Int, 4)
    }
    func testValidButTamperedSQLiteRecoveryIsRejected() async throws {
        let path = "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        try await sql(path, "CREATE TABLE LSQuarantineEvent(id INTEGER); INSERT INTO LSQuarantineEvent VALUES(1);")
        let plan = await engine.preview(.cleanQuarantineEvents)
        let result = await executeAll(plan); XCTAssertEqual(result.status, .success)
        let history = try await engine.history()
        let backup = try XCTUnwrap(history.first?.entries.first?.backup)
        let tamper = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/sqlite3", arguments: [backup.path, "INSERT INTO LSQuarantineEvent VALUES(999);"], timeoutSeconds: 3))
        XCTAssertEqual(tamper.exitCode, 0)
        do { try await engine.restore(history[0].id); XCTFail("tampered recovery") } catch {}
        let count = try await sql(path, "SELECT COUNT(*) FROM LSQuarantineEvent;"); XCTAssertEqual(count, "0")
    }
    func testLoginAuditShowsMissingTargetsAndRetainsExternalVolumes() {
        let output = "Name: Missing Tool\nURL: file:///Applications/OrbitMissingLoginFixture.app/\nName: External\nURL: file:///Volumes/Unplugged/Example.app/\n"
        let findings = MaintenanceEngine.loginFindings(output, home: root)
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings[0].contains("目标已不存在"))
        XCTAssertTrue(findings[1].contains("外置磁盘"))
    }
    func testOldSavedStateDirectoryWithRecentChildIsKept() async throws {
        let data = try file("Library/Saved Application State/org.example.recent.savedState/state.data")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: data.deletingLastPathComponent().path)
        let plan = await engine.preview(.cleanSavedState)
        XCTAssertTrue(plan.candidates.isEmpty)
    }
    func testRealLsofAllowsClosedDatabaseWithMissingSidecarsAndProtectsOpenFile() async throws {
        engine = MaintenanceEngine(home: root, checkOpenFiles: true)
        let path = "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        try await sql(path, "CREATE TABLE LSQuarantineEvent(id INTEGER); INSERT INTO LSQuarantineEvent VALUES(1);")
        let plan = await engine.preview(.cleanQuarantineEvents)
        let handle = try FileHandle(forReadingFrom: url(path))
        let busy = await executeAll(plan)
        XCTAssertEqual(busy.status, .failed)
        try handle.close()
        let closed = await executeAll(plan)
        XCTAssertEqual(closed.status, .success, closed.message)
        let count = try await sql(path, "SELECT COUNT(*) FROM LSQuarantineEvent;"); XCTAssertEqual(count, "0")
    }
    func testAuthorizedLoginAuditUsesFixedReadOnlyCommandAndHandlesCancelledAuthentication() async {
        let done = await engine.authorizedLoginAudit(runner: { command in
            XCTAssertEqual(command.executable, "/usr/bin/osascript")
            XCTAssertEqual(command.arguments, ["-e", "do shell script \"/usr/bin/sfltool dumpbtm\" with administrator privileges"])
            return MaintenanceCommandResult(exitCode: 0, output: "Name: Gone\nURL: file:///Applications/OrbitMissingFixture.app/")
        })
        XCTAssertEqual(done.findings.count, 1)
        XCTAssertTrue(done.findings[0].contains("目标已不存在"))
        XCTAssertTrue(done.candidates.isEmpty)
        let cancelled = await engine.authorizedLoginAudit(runner: { _ in MaintenanceCommandResult(exitCode: 1, output: "User canceled. (-128)") })
        XCTAssertTrue(cancelled.findings.isEmpty)
        XCTAssertTrue(cancelled.warnings[0].contains("取消"))
    }
}
