import XCTest
import Darwin
@testable import OrbitCore

final class StartupItemsTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        let resolved = realpath(FileManager.default.temporaryDirectory.path, nil)!
        home = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("orbit-startup-" + UUID().uuidString)
        free(resolved)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    @discardableResult private func config(label: String = "com.example.fixture") throws -> URL {
        let url = home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": false], format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    actor Calls {
        var values: [[String]] = []
        func append(_ value: [String]) { values.append(value) }
    }

    func testUserConfigDisableEnableIsReversibleAndUsesFixedLaunchctlArguments() async throws {
        let original = try config()
        let calls = Calls()
        let service = StartupItemsService(home: home, runner: { args in await calls.append(args); return LaunchctlResult(status: 0) }, includeSystem: false)
        let first = await service.scan()
        let item = try XCTUnwrap(first.items.first)
        XCTAssertTrue(item.canToggle)
        XCTAssertTrue(item.isEnabled)
        try await service.setEnabled(false, item: item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let disabledScan = await service.scan()
        let disabled = try XCTUnwrap(disabledScan.items.first)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.originalURL, original)
        try await service.setEnabled(true, item: disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let after = await service.scan()
        XCTAssertEqual(after.items.count, 1)
        XCTAssertTrue(after.items[0].isEnabled)
        let commands = await calls.values
        XCTAssertEqual(commands, [["bootout", "gui/\(getuid())/com.example.fixture"], ["bootstrap", "gui/\(getuid())", original.path]])
    }

    func testChangedOrAppleConfigCannotBeToggled() async throws {
        let original = try config()
        let apple = try config(label: "com.apple.protected-fixture")
        let calls = Calls()
        let service = StartupItemsService(home: home, runner: { args in await calls.append(args); return LaunchctlResult(status: 0) }, includeSystem: false)
        let scan = await service.scan()
        XCTAssertFalse(try XCTUnwrap(scan.items.first { $0.url == apple }).canToggle)
        let normal = try XCTUnwrap(scan.items.first { $0.url == original })
        try Data("changed".utf8).write(to: original)
        do { try await service.setEnabled(false, item: normal); XCTFail("Changed config should not be unloaded") } catch { }
        let commands = await calls.values
        XCTAssertTrue(commands.isEmpty)
    }

    func testBootstrapFailureRollsConfigurationBackToDisabledLocation() async throws {
        let original = try config()
        let service = StartupItemsService(home: home, runner: { args in LaunchctlResult(status: args.first == "bootstrap" ? 5 : 0, output: "fixture refusal") }, includeSystem: false)
        let before = await service.scan()
        try await service.setEnabled(false, item: XCTUnwrap(before.items.first))
        let disabledScan = await service.scan()
        let disabled = try XCTUnwrap(disabledScan.items.first)
        do { try await service.setEnabled(true, item: disabled); XCTFail("Bootstrap should fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let after = await service.scan()
        XCTAssertEqual(after.items.count, 1)
        XCTAssertFalse(after.items[0].isEnabled)
    }

    func testInvalidJournalAndSymlinkFailClosed() async throws {
        let original = try config()
        let root = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.plist"), withDestinationURL: original)
        let service = StartupItemsService(home: home, runner: { _ in XCTFail("No real or mocked command should run"); return LaunchctlResult(status: 0) }, includeSystem: false)
        let scan = await service.scan()
        XCTAssertEqual(scan.items.count, 1)
        XCTAssertFalse(scan.warnings.isEmpty)
        let journal = home.appendingPathComponent("Library/Application Support/Orbit/DisabledLaunchAgents/index.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: journal)
        do { try await service.setEnabled(false, item: XCTUnwrap(scan.items.first)); XCTFail("Invalid journal must stop mutation") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testInterruptedEnableDoesNotLeaveAnUnchangeableStaleRecord() async throws {
        let original = try config()
        let service = StartupItemsService(home: home, runner: { _ in LaunchctlResult(status: 0) }, includeSystem: false)
        let first = await service.scan()
        try await service.setEnabled(false, item: XCTUnwrap(first.items.first))
        let disabledScan = await service.scan()
        let disabled = try XCTUnwrap(disabledScan.items.first)
        // Simulate interruption between configuration restoration and journal commit.
        try FileManager.default.moveItem(at: disabled.url, to: original)
        let interrupted = await service.scan()
        XCTAssertTrue(try XCTUnwrap(interrupted.items.first).isEnabled)
        try await service.setEnabled(false, item: XCTUnwrap(interrupted.items.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let retried = await service.scan()
        XCTAssertEqual(retried.items.count, 1)
        XCTAssertFalse(retried.items[0].isEnabled)
    }

    func testBootstrapFailureNeverMovesAReplacementConfiguration() async throws {
        let original = try config()
        let replacement = Data("an external replacement configuration".utf8)
        let service = StartupItemsService(home: home, runner: { args in
            if args.first == "bootstrap" {
                try replacement.write(to: original, options: .atomic)
                return LaunchctlResult(status: 5, output: "fixture bootstrap failure")
            }
            return LaunchctlResult(status: 0)
        }, includeSystem: false)
        let initial = await service.scan()
        try await service.setEnabled(false, item: XCTUnwrap(initial.items.first))
        let disabledScan = await service.scan()
        let disabled = try XCTUnwrap(disabledScan.items.first)
        do { try await service.setEnabled(true, item: disabled); XCTFail("Changed source must stop rollback") }
        catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertEqual(try Data(contentsOf: original), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabled.url.path))
    }

    actor SuspendedCommand {
        var isWaiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func pause() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testMutationLockSurvivesAwaitAndRejectsAnotherServiceInstance() async throws {
        try config()
        let gate = SuspendedCommand()
        let first = StartupItemsService(home: home, runner: { _ in await gate.pause(); return LaunchctlResult(status: 0) }, includeSystem: false)
        let second = StartupItemsService(home: home, runner: { _ in XCTFail("A second mutation must not launch a command"); return LaunchctlResult(status: 0) }, includeSystem: false)
        let initial = await first.scan()
        let item = try XCTUnwrap(initial.items.first)
        let task = Task { try await first.setEnabled(false, item: item) }
        for _ in 0..<1000 {
            if await gate.isWaiting { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        do { try await second.setEnabled(false, item: item); XCTFail("The mutation lock must remain held across await") }
        catch { XCTAssertTrue(error.localizedDescription.contains("另一项")) }
        await gate.release()
        try await task.value
        let result = await first.scan()
        XCTAssertEqual(result.items.count, 1)
        XCTAssertFalse(result.items[0].isEnabled)
    }
}
