import XCTest
import AppKit
import OrbitCore
@testable import Orbit

@MainActor
final class AutomaticUpdateRoutingTests: XCTestCase {
    private var previousSetting: Any?
    override func setUp() {
        super.setUp()
        previousSetting = UserDefaults.standard.object(forKey: "automaticUpdateIDs")
        UserDefaults.standard.removeObject(forKey: "automaticUpdateIDs")
    }
    override func tearDown() {
        if let previousSetting { UserDefaults.standard.set(previousSetting, forKey: "automaticUpdateIDs") }
        else { UserDefaults.standard.removeObject(forKey: "automaticUpdateIDs") }
        super.tearDown()
    }
    private func descriptor(_ path: String, id: String = "org.example.orbit.routing") -> AppDescriptor {
        AppDescriptor(url: URL(fileURLWithPath: path), name: "Fixture", bundleID: id, version: "1", appcastURL: nil)
    }
    func testOptInUsesExactInstallationAndOptOutRemovesPendingWork() async {
        let state = AppState()
        defer { state.stop() }
        let first = descriptor("/Applications/OrbitRoutingFixture.app")
        let second = descriptor("/Users/fixture/Applications/OrbitRoutingFixture.app")
        state.apps = [first, second]; state.working = true
        state.setAutomaticUpdate(true, for: first)
        XCTAssertEqual(state.automaticUpdateIDs, [first.id])
        XCTAssertFalse(state.automaticUpdateIDs.contains(second.id))
        XCTAssertEqual(state.pendingAutomaticUpdates, [first.id])
        state.setAutomaticUpdate(false, for: first)
        XCTAssertTrue(state.automaticUpdateIDs.isEmpty)
        XCTAssertTrue(state.pendingAutomaticUpdates.isEmpty)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    func testLegacyBundleSettingsMigrateToKnownInstallationPaths() {
        let state = AppState(); defer { state.stop() }
        let first = descriptor("/Applications/OrbitRoutingFixture.app")
        let unrelated = descriptor("/Applications/UnrelatedRoutingFixture.app", id: "org.example.other")
        state.apps = [first, unrelated]; state.automaticUpdateIDs = [first.bundleID]
        state.migrateAutomaticUpdateTargets()
        XCTAssertEqual(state.automaticUpdateIDs, [first.id])
    }
    func testExitNotificationQueuesEnabledInstallationWhileBusyAndStopRemovesObserver() async throws {
        let state = AppState(); defer { state.stop() }
        // xctest itself has no app bundle on macOS. This only supplies read-only
        // event metadata; posting to the process-local center does not quit that app.
        let current = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
        let bundleID = try XCTUnwrap(current.bundleIdentifier)
        let first = descriptor("/Applications/OrbitRoutingFixture.app", id: bundleID)
        let other = descriptor("/Applications/OtherRoutingFixture.app", id: bundleID)
        state.apps = [first, other]; state.working = true
        state.automaticUpdateIDs = [first.id]
        state.startAutomaticUpdates()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: current])
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.pendingAutomaticUpdates, [first.id])
        XCTAssertFalse(state.pendingAutomaticUpdates.contains(other.id))
        state.stop(); state.pendingAutomaticUpdates = []
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: current])
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(state.pendingAutomaticUpdates.isEmpty)
    }
}
