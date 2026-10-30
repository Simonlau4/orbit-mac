import XCTest
import Darwin
@testable import OrbitCore

final class AIPackagesTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var npm: URL!
    private var brew: URL!
    private var locations: AIPackageLocations!
    private var recovery: URL { home.appendingPathComponent("Library/Application Support/Orbit/AIPackageRecovery") }
    override func setUpWithError() throws {
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        root = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-ai-packages-" + UUID().uuidString)
        home = root.appendingPathComponent("home"); npm = home.appendingPathComponent("npm"); brew = home.appendingPathComponent("brew")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        locations = AIPackageLocations(npmPrefixes: [npm], homebrewPrefixes: [brew])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func file(_ url: URL, _ data: Data = Data("fixture".utf8)) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url); return url
    }
    private func json(_ url: URL, _ values: [String: Any]) throws { try file(url, JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) }
    private func link(_ url: URL, _ target: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }
    @discardableResult private func npmPackage(_ name: String = "@openai/codex", bin: String = "codex", dependencies: [String: String] = [:]) throws -> URL {
        let package = npm.appendingPathComponent("lib/node_modules/" + name)
        try file(package.appendingPathComponent("bin/cli.js"), Data("console.log('fixture')".utf8))
        try json(package.appendingPathComponent("package.json"), ["name": name, "version": "1.2.3", "bin": [bin: "bin/cli.js"], "dependencies": dependencies])
        try link(npm.appendingPathComponent("bin/" + bin), "../lib/node_modules/" + name + "/bin/cli.js")
        return package
    }
    @discardableResult private func formula(_ name: String = "ollama", dependencies: [String] = []) throws -> URL {
        let rack = brew.appendingPathComponent("Cellar/" + name), keg = rack.appendingPathComponent("1.2.3")
        try file(keg.appendingPathComponent("bin/" + name))
        try json(keg.appendingPathComponent("INSTALL_RECEIPT.json"), ["runtime_dependencies": dependencies.map { ["full_name": $0, "version": "1.0"] }, "source": ["tap": "homebrew/core"]])
        try link(brew.appendingPathComponent("bin/" + name), "../Cellar/" + name + "/1.2.3/bin/" + name)
        try link(brew.appendingPathComponent("opt/" + name), "../Cellar/" + name + "/1.2.3")
        return rack
    }
    @discardableResult private func cask(extraArtifact: [String: Any]? = nil) throws -> URL {
        let rack = brew.appendingPathComponent("Caskroom/claude-code")
        try file(rack.appendingPathComponent("2.0.0/claude"))
        try json(rack.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"), ["runtime_dependencies": [String: Any](), "source": ["tap": "homebrew/cask", "version": "2.0.0"], "uninstall_flight_blocks": false, "uninstall_artifacts": []])
        var artifacts: [[String: Any]] = [["binary": ["claude"], "target": "$HOMEBREW_PREFIX/bin/claude"], ["zap": [["trash": "~/.claude"]]]]
        if let extraArtifact { artifacts.append(extraArtifact) }
        try json(rack.appendingPathComponent(".metadata/2.0.0/202610270000/Casks/claude-code.json"), ["token": "claude-code", "version": "2.0.0", "artifacts": artifacts])
        try link(brew.appendingPathComponent("bin/claude"), "../Caskroom/claude-code/2.0.0/claude")
        return rack
    }
    private func scan() async -> AIPackageScan { await AIPackageScanner(home: home, locations: locations, activity: { [] }).scan() }
    private func firstCandidate() async throws -> AIPackageCandidate {
        let result = await scan()
        return try XCTUnwrap(result.candidates.first, result.retained.map(\.reason).joined(separator: "\n") + result.warnings.joined(separator: "\n"))
    }
    private func store(activity: @escaping AIActivityProvider = { [] }) -> AIPackageStore { AIPackageStore(home: home, locations: locations, activity: activity) }
    private func writeHistory(_ records: [AIPackageRecord]) throws { try JSONEncoder().encode(records).write(to: recovery.appendingPathComponent("history.json"), options: .atomic) }

    func testNpmProgramAndExactCliRoundTripKeepsPersonalDataAndSharedDependencies() async throws {
        let package = try npmPackage(dependencies: ["shared": "*"])
        let shared = try npmPackage("shared", bin: "shared")
        let credential = try file(home.appendingPathComponent(".codex/auth.json"), Data("private-fixture".utf8))
        let memory = try file(home.appendingPathComponent(".claude/skills/keep.md"))
        let result = await scan()
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.dependencies, ["shared"])
        XCTAssertEqual(candidate.paths.count, 2)
        XCTAssertEqual(candidate.referencedBy, [])
        XCTAssertGreaterThan(candidate.bytes, 0)
        let service = store(), record = try await service.remove(candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: npm.appendingPathComponent("bin/codex").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertEqual(try Data(contentsOf: credential), Data("private-fixture".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memory.path))
        try await service.restore(record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: npm.appendingPathComponent("bin/codex").path), "../lib/node_modules/@openai/codex/bin/cli.js")
        let history = try await service.history(); XCTAssertTrue(try XCTUnwrap(history.first).isRestored)
    }

    func testUnknownGlobalManifestOrNewDependentPreventsRemoval() async throws {
        let package = try npmPackage()
        let initial = try await firstCandidate()
        _ = try npmPackage("wrapper", bin: "wrapper", dependencies: ["@openai/codex": "*"])
        let referenced = await scan(); XCTAssertTrue(referenced.candidates.isEmpty)
        XCTAssertTrue(referenced.retained.contains { $0.reason.contains("引用") })
        do { _ = try await store().remove(initial); XCTFail("fresh dependent must be rechecked") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        try FileManager.default.removeItem(at: npm.appendingPathComponent("lib/node_modules/wrapper/package.json"))
        let unknown = await scan(); XCTAssertTrue(unknown.candidates.isEmpty)
        XCTAssertTrue(unknown.retained.contains { $0.reason.contains("不完整") })
    }

    func testAcrossBatchesNeverMovesSharedGlobalDependency() async throws {
        _ = try npmPackage(dependencies: ["shared": "*"])
        _ = try npmPackage("@anthropic-ai/claude-code", bin: "claude", dependencies: ["shared": "*"])
        let shared = try npmPackage("shared", bin: "shared")
        let initial = await scan(); XCTAssertEqual(initial.candidates.count, 2)
        let service = store()
        let first = try await service.remove(initial.candidates[0])
        let second = try await service.remove(initial.candidates[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        try await service.restore(first.id); try await service.restore(second.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    }

    func testActiveToolAndPostPreviewFileChangeAreKept() async throws {
        let package = try npmPackage()
        let active = await AIPackageScanner(home: home, locations: locations, activity: { [.codex] }).scan()
        XCTAssertTrue(active.candidates.isEmpty)
        let initial = try await firstCandidate()
        try Data("changed".utf8).write(to: package.appendingPathComponent("bin/cli.js"))
        do { _ = try await store().remove(initial); XCTFail("changed") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
    }

    func testOutboundSymlinkHardlinkAndPrivateConfigInsideProgramAreKept() async throws {
        let package = try npmPackage()
        let escape = package.appendingPathComponent("escape")
        try link(escape, "../../../../outside")
        let checked = await scan(); XCTAssertTrue(checked.candidates.isEmpty)
        try FileManager.default.removeItem(at: escape)
        let hard = home.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: package.appendingPathComponent("bin/cli.js"), to: hard)
        let checkedHardlink = await scan(); XCTAssertTrue(checkedHardlink.candidates.isEmpty)
        try FileManager.default.removeItem(at: hard)
        _ = try file(package.appendingPathComponent(".npmrc"), Data("do-not-read".utf8))
        let credential = await scan(); XCTAssertTrue(credential.candidates.isEmpty)
        XCTAssertTrue(credential.retained.contains { $0.reason.contains("凭据") })
    }

    func testRestoreConflictAndModifiedRecoveryNeverOverwrite() async throws {
        let package = try npmPackage(), initial = try await firstCandidate()
        let service = store(), record = try await service.remove(initial)
        let current = try file(package.appendingPathComponent("new-version"), Data("new".utf8))
        do { try await service.restore(record.id); XCTFail("conflict") } catch {}
        XCTAssertEqual(try Data(contentsOf: current), Data("new".utf8))
        try FileManager.default.removeItem(at: package)
        let program = try XCTUnwrap(record.moves.first { $0.originalURL.path == package.path })
        try Data("tamper".utf8).write(to: program.storedURL.appendingPathComponent("bin/cli.js"))
        do { try await service.restore(record.id); XCTFail("tampered") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }

    func testInterruptedRemovalAndRestoreAreReconciled() async throws {
        let package = try npmPackage(), candidate = try await firstCandidate()
        let service = store(), record = try await service.remove(candidate)
        var history = [record]
        history[0].moves[0].state = .pending // Rename succeeded just before the process stopped saving.
        let programIndex = try XCTUnwrap(history[0].moves.firstIndex { $0.originalURL.path == package.path })
        history[0].moves[programIndex].state = .restoring
        try writeHistory(history)
        try FileManager.default.moveItem(at: history[0].moves[programIndex].storedURL, to: package)
        try await service.restore(record.id)
        let reconciled = try await service.history()
        XCTAssertTrue(try XCTUnwrap(reconciled.first).isRestored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: npm.appendingPathComponent("bin/codex").path))
    }

    func testIndependentHomebrewFormulaAndItsOptLinkRoundTrip() async throws {
        let package = try formula()
        let result = await scan(), candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.kind, .homebrewFormula)
        XCTAssertEqual(candidate.paths.count, 3)
        let service = store(), record = try await service.remove(candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        try await service.restore(record.id)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: brew.appendingPathComponent("opt/ollama").path), "../Cellar/ollama/1.2.3")
    }

    func testHomebrewDependentsUnknownReceiptsAndExportedLibrariesAreKept() async throws {
        let package = try formula()
        _ = try formula("dependent", dependencies: ["ollama"])
        let dependent = await scan(); XCTAssertTrue(dependent.candidates.isEmpty)
        XCTAssertTrue(dependent.retained.contains { $0.reason.contains("引用") })
        try FileManager.default.removeItem(at: brew.appendingPathComponent("Cellar/dependent"))
        _ = try file(package.appendingPathComponent("1.2.3/lib/libfixture.dylib"))
        let library = await scan(); XCTAssertTrue(library.candidates.isEmpty)
        XCTAssertTrue(library.retained.contains { $0.reason.contains("动态依赖") })
        try FileManager.default.removeItem(at: package.appendingPathComponent("1.2.3/lib"))
        _ = try file(brew.appendingPathComponent("Caskroom/unknown/.metadata/INSTALL_RECEIPT.json"), Data("unknown-schema".utf8))
        let unknown = await scan(); XCTAssertTrue(unknown.candidates.isEmpty)
        XCTAssertTrue(unknown.retained.contains { $0.reason.contains("不完整") })
    }

    func testBinaryOnlyCaskRoundTripNeverRunsZapAndGeneratedArtifactsAreKept() async throws {
        let program = try cask()
        let config = try file(home.appendingPathComponent(".claude/settings.json"), Data("keep".utf8))
        let candidate = try await firstCandidate()
        XCTAssertEqual(candidate.kind, .homebrewCask)
        let service = store(), record = try await service.remove(candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: program.path))
        XCTAssertEqual(try Data(contentsOf: config), Data("keep".utf8))
        try await service.restore(record.id)
        let manifest = program.appendingPathComponent(".metadata/2.0.0/202610270000/Casks/claude-code.json")
        try json(manifest, ["token": "claude-code", "version": "2.0.0", "artifacts": [["binary": ["claude"]], ["generate_completions_from_executable": ["claude"]]]])
        let generated = await scan(); XCTAssertTrue(generated.candidates.isEmpty)
        XCTAssertTrue(generated.retained.contains { $0.reason.contains("artifact") })
    }

    func testCrossInstanceLockSurvivesFreshScanAwaitAndCorruptHistoryFailsClosed() async throws {
        let package = try npmPackage(), candidate = try await firstCandidate()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = store(activity: { entered.signal(); _ = release.wait(timeout: .now() + 5); return [] })
        let task = Task { try await first.remove(candidate) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let second = store()
        do { _ = try await second.remove(candidate); XCTFail("concurrent lock") } catch { XCTAssertTrue(error.localizedDescription.contains("正在进行")) }
        release.signal(); release.signal(); release.signal()
        let record = try await task.value
        try await second.restore(record.id)
        try Data("corrupt".utf8).write(to: recovery.appendingPathComponent("history.json"))
        do { _ = try await second.remove(candidate); XCTFail("corrupt history") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
    }

    func testChangedCliLinkAndNonWritableProgramParentAreKept() async throws {
        let package = try npmPackage(), candidate = try await firstCandidate()
        let cli = npm.appendingPathComponent("bin/codex")
        try FileManager.default.removeItem(at: cli)
        try link(cli, "../../outside")
        do { _ = try await store().remove(candidate); XCTFail("changed CLI") } catch {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: cli.path), "../../outside")
        try FileManager.default.removeItem(at: cli)
        try link(cli, "../lib/node_modules/@openai/codex/bin/cli.js")
        let parent = package.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let locked = await scan(); XCTAssertTrue(locked.candidates.isEmpty)
        XCTAssertTrue(locked.retained.contains { $0.reason.contains("可写") })
    }

    func testCaskUninstallHooksAreNotSilentlySkipped() async throws {
        let program = try cask()
        try json(program.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"), ["runtime_dependencies": [String: Any](), "source": ["tap": "homebrew/cask", "version": "2.0.0"], "uninstall_flight_blocks": true, "uninstall_artifacts": []])
        let result = await scan()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.retained.contains { $0.reason.contains("卸载脚本") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: program.path))
    }

    func testPinnedSourceParentSymlinkSwapNeverMovesOutsideFile() async throws {
        let package = try npmPackage(), candidate = try await firstCandidate()
        let bin = npm.appendingPathComponent("bin"), held = npm.appendingPathComponent("bin-held")
        let outside = home.appendingPathComponent("outside-bin")
        let victim = try file(outside.appendingPathComponent("codex"), Data("outside-data".utf8))
        let protectedStore = AIPackageStore(home: home, locations: locations, activity: { [] }, beforeRename: { source, _ in
            guard source.deletingLastPathComponent().path == bin.path else { return }
            try FileManager.default.moveItem(at: bin, to: held)
            try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: outside)
        })
        do { _ = try await protectedStore.remove(candidate); XCTFail("pinned parent changed") } catch {}
        XCTAssertEqual(try Data(contentsOf: victim), Data("outside-data".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: held.appendingPathComponent("codex").path), "../lib/node_modules/@openai/codex/bin/cli.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        let records = try await protectedStore.history()
        XCTAssertTrue(records[0].moves.allSatisfy { $0.state == .pending && !FileManager.default.fileExists(atPath: $0.storedURL.path) })
    }

    func testPinnedRestoreDestinationParentSwapKeepsRecoveryAndOutsideFile() async throws {
        let package = try npmPackage(), candidate = try await firstCandidate()
        let service = store(), record = try await service.remove(candidate)
        let parent = package.deletingLastPathComponent(), held = parent.deletingLastPathComponent().appendingPathComponent("scope-held")
        let outside = home.appendingPathComponent("outside-scope")
        let victim = try file(outside.appendingPathComponent("codex"), Data("outside-data".utf8))
        let protectedStore = AIPackageStore(home: home, locations: locations, activity: { [] }, beforeRename: { _, destination in
            guard destination.path == package.path else { return }
            try FileManager.default.moveItem(at: parent, to: held)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        })
        do { try await protectedStore.restore(record.id); XCTFail("pinned restore parent changed") } catch {}
        XCTAssertEqual(try Data(contentsOf: victim), Data("outside-data".utf8))
        let program = try XCTUnwrap(record.moves.first { $0.originalURL.path == package.path })
        XCTAssertTrue(FileManager.default.fileExists(atPath: program.storedURL.appendingPathComponent("bin/cli.js").path))
        let records = try await protectedStore.history()
        XCTAssertFalse(records[0].isRestored)
    }

    func testExistingBrewOperationLockAndNpmLegacyLockPreventRemoval() async throws {
        let package = try formula(), candidate = try await firstCandidate()
        let lock = try file(brew.appendingPathComponent("var/homebrew/locks/ollama.formula.lock"), Data())
        let handle = try FileHandle(forUpdating: lock)
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        do { _ = try await store().remove(candidate); XCTFail("brew operation lock") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        flock(handle.fileDescriptor, LOCK_UN); try handle.close()
        let service = store(), record = try await service.remove(candidate)
        try await service.restore(record.id)

        _ = try npmPackage()
        let npmScan = await scan(), npmCandidate = try XCTUnwrap(npmScan.candidates.first { $0.kind == .npm })
        _ = try file(home.appendingPathComponent(".npm/_locks/install.lock"), Data())
        do { _ = try await service.remove(npmCandidate); XCTFail("npm legacy lock") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: npmCandidate.packageURL.path))
    }
}
