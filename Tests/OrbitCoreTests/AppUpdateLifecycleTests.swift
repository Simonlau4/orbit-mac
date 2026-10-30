import XCTest
import Foundation
import AppKit
import Darwin
@testable import OrbitCore

final class AppUpdateLifecycleTests: XCTestCase {
    func testSystemLifecycleStartsQuitsAndRelaunchesOwnAdhocFixture() async throws {
        let fixture = try await LifecycleFixture.create()
        let lifecycle = AppUpdateLifecycle.system
        do {
            let initiallyRunning = await lifecycle.isRunning(fixture.app)
            XCTAssertFalse(initiallyRunning)
            try await lifecycle.relaunch(fixture.app)
            let firstStarted = await LifecycleFixture.waitForRunning(fixture.app, lifecycle: lifecycle)
            guard firstStarted else { throw LifecycleFixtureError.didNotStart }
            let firstQuit = await lifecycle.requestQuit(fixture.app)
            XCTAssertTrue(firstQuit)
            let runningAfterFirstQuit = await lifecycle.isRunning(fixture.app)
            XCTAssertFalse(runningAfterFirstQuit)
            guard firstQuit, !runningAfterFirstQuit else { throw LifecycleFixtureError.didNotQuit }
            try await lifecycle.relaunch(fixture.app)
            let secondStarted = await LifecycleFixture.waitForRunning(fixture.app, lifecycle: lifecycle)
            guard secondStarted else { throw LifecycleFixtureError.didNotStart }
            let secondQuit = await lifecycle.requestQuit(fixture.app)
            XCTAssertTrue(secondQuit)
            let runningAfterSecondQuit = await lifecycle.isRunning(fixture.app)
            XCTAssertFalse(runningAfterSecondQuit)
            guard secondQuit, !runningAfterSecondQuit else { throw LifecycleFixtureError.didNotQuit }
            let events = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
            let starts = events.filter { $0.hasPrefix("start ") }
            let quits = events.filter { $0.hasPrefix("quit ") }
            XCTAssertEqual(starts.count, 2)
            XCTAssertEqual(quits.count, 2)
            XCTAssertNotEqual(starts.first, starts.last)
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            await LifecycleFixture.cleanupOnlyOwnApp(fixture.app)
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
    }
}

private enum LifecycleFixtureError: Error { case didNotStart, didNotQuit, commandFailed(String) }

private struct LifecycleFixture {
    let root: URL
    let app: URL
    let log: URL

    static func create() async throws -> LifecycleFixture {
        let actual = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(actual) }
        let root = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-lifecycle-" + UUID().uuidString)
        let app = root.appendingPathComponent("OrbitLifecycleFixture.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = root.appendingPathComponent("events.log")
        let source = root.appendingPathComponent("fixture.swift")
        try Data(fixtureSource.utf8).write(to: source)
        let info: [String: Any] = ["CFBundleIdentifier": "com.orbitmac.orbit.lifecycle.fixture." + UUID().uuidString.lowercased(),
                                   "CFBundleName": "Orbit Lifecycle Fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
                                   "CFBundleVersion": "1", "CFBundleShortVersionString": "1", "LSMinimumSystemVersion": "14.0",
                                   "LSUIElement": true, "NSPrincipalClass": "NSApplication", "OrbitFixtureLog": log.path]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        do {
            try await command("/usr/bin/xcrun", ["swiftc", "-parse-as-library", source.path, "-framework", "AppKit", "-o", macOS.appendingPathComponent("Fixture").path], timeout: 60)
            try await command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path], timeout: 15)
            return LifecycleFixture(root: root, app: app, log: log)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    static func waitForRunning(_ url: URL, lifecycle: AppUpdateLifecycle) async -> Bool {
        for _ in 0..<50 {
            if await lifecycle.isRunning(url) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    static func cleanupOnlyOwnApp(_ url: URL) async {
        let lifecycle = AppUpdateLifecycle.system
        if await lifecycle.isRunning(url) {
            let stopped = await lifecycle.requestQuit(url)
            if !stopped {
                // Only this generated fixture can be force-stopped after a failed assertion.
                _ = await MainActor.run {
                    NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == url.path }.map { $0.forceTerminate() }
                }
            }
        }
    }

    static func command(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws {
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: path, arguments: arguments, timeoutSeconds: timeout))
        guard result.exitCode == 0, !result.cancelled, !result.timedOut else { throw LifecycleFixtureError.commandFailed(result.output) }
    }

    static let fixtureSource = #"""
    import AppKit
    import Foundation

    @MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) { record("start") }
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
        func applicationWillTerminate(_ notification: Notification) { record("quit") }
        private func record(_ event: String) {
            guard let path = Bundle.main.object(forInfoDictionaryKey: "OrbitFixtureLog") as? String else { return }
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\(event) \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
            try? handle.synchronize()
        }
    }
    @main struct FixtureMain {
        @MainActor static func main() {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let delegate = FixtureDelegate()
            application.delegate = delegate
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { application.terminate(nil) }
            withExtendedLifetime(delegate) { application.run() }
        }
    }
    """#
}
