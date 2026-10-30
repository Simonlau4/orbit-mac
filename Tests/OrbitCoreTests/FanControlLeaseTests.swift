import XCTest
@testable import OrbitCore

final class FanControlLeaseTests: XCTestCase {
    func testLeaseExpiresAtTenSecondsAndRejectsFutureRequests() throws {
        let issued = Date(timeIntervalSince1970: 1_000_000)
        let lease = FanControlLease(id: UUID(), mode: .cool, issuedAt: issued)
        XCTAssertTrue(lease.valid(at: issued))
        XCTAssertTrue(lease.valid(at: issued.addingTimeInterval(9.999)))
        XCTAssertFalse(lease.valid(at: issued.addingTimeInterval(10)))
        XCTAssertTrue(lease.valid(at: issued.addingTimeInterval(-2)))
        XCTAssertFalse(lease.valid(at: issued.addingTimeInterval(-2.001)))
        let roundtrip = try JSONDecoder().decode(FanControlLease.self, from: JSONEncoder().encode(lease))
        XCTAssertEqual(roundtrip.id, lease.id)
        XCTAssertEqual(roundtrip.mode, lease.mode)
        XCTAssertEqual(roundtrip.issuedAt, lease.issuedAt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(lease)) as? [String: Any])
        object["mode"] = "write-arbitrary-key"
        XCTAssertThrowsError(try JSONDecoder().decode(FanControlLease.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testPowerObserverRegistersAndClosesWithoutWritingHardware() throws {
        let observer = try ThermalSleepGuard(hardware: ThermalFanHardware())
        XCTAssertFalse(observer.shouldStop)
        XCTAssertNil(observer.didRestoreForSleep)
        observer.close()
        observer.close()
    }

    func testSleepBeforeControlPreventsAllLaterWrites() {
        let fixture = SleepFixture()
        let observer = fixture.observer()
        observer.prepareForSleep()
        XCTAssertTrue(observer.shouldStop)
        XCTAssertNil(observer.didRestoreForSleep)
        XCTAssertThrowsError(try observer.apply(mode: .cool, targetFraction: 0.6))
        XCTAssertEqual(fixture.events, [])
    }

    func testSleepRestoresBeforeReturningAndWakeDoesNotResumeControl() throws {
        let fixture = SleepFixture()
        let observer = fixture.observer()
        _ = try observer.apply(mode: .maxCool, targetFraction: 1)
        observer.powerMessage(ThermalSleepGuard.systemWillSleep, notificationID: 0)
        XCTAssertTrue(observer.shouldStop)
        XCTAssertEqual(observer.didRestoreForSleep, true)
        XCTAssertNil(observer.lastSleepRestoreError)
        XCTAssertEqual(fixture.events, ["apply", "restore"])
        observer.powerMessage(ThermalSleepGuard.systemHasPoweredOn, notificationID: 0)
        XCTAssertThrowsError(try observer.apply(mode: .cool, targetFraction: 0.6))
        XCTAssertEqual(fixture.events, ["apply", "restore", "restore"])
    }

    func testSleepRestoreFailureStaysVisibleAndCannotResume() throws {
        let fixture = SleepFixture()
        fixture.failRestore = true
        let observer = fixture.observer()
        _ = try observer.apply(mode: .cool, targetFraction: 0.8)
        observer.prepareForSleep()
        XCTAssertEqual(observer.didRestoreForSleep, false)
        XCTAssertFalse(observer.lastSleepRestoreError?.isEmpty ?? true)
        XCTAssertEqual(fixture.events.filter { $0 == "restore" }.count, 3)
        XCTAssertThrowsError(try observer.apply(mode: .maxCool, targetFraction: 1))
    }

    func testSleepSerializesWithAnAlreadyRunningWrite() throws {
        let fixture = SleepFixture()
        let applyStarted = DispatchSemaphore(value: 0)
        let allowApplyToFinish = DispatchSemaphore(value: 0)
        let sleepStarted = DispatchSemaphore(value: 0)
        let sleepFinished = DispatchSemaphore(value: 0)
        let observer = ThermalSleepGuard(apply: { _, _ in
            fixture.record("apply-start")
            applyStarted.signal()
            _ = allowApplyToFinish.wait(timeout: .now() + 5)
            fixture.record("apply-finish")
            return fixture.snapshot(mode: .manual)
        }, restore: {
            fixture.record("restore")
            return fixture.snapshot(mode: .automatic)
        })
        let writes = DispatchGroup()
        writes.enter()
        DispatchQueue.global().async {
            defer { writes.leave() }
            _ = try? observer.apply(mode: .cool, targetFraction: 0.6)
        }
        XCTAssertEqual(applyStarted.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            sleepStarted.signal()
            observer.prepareForSleep()
            sleepFinished.signal()
        }
        XCTAssertEqual(sleepStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sleepFinished.wait(timeout: .now() + 0.05), .timedOut)
        allowApplyToFinish.signal()
        XCTAssertEqual(writes.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sleepFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fixture.events, ["apply-start", "apply-finish", "restore"])
        XCTAssertThrowsError(try observer.apply(mode: .cool, targetFraction: 0.6))
    }
}

private final class SleepFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var failRestore = false
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ event: String) { lock.lock(); defer { lock.unlock() }; recorded.append(event) }
    func observer() -> ThermalSleepGuard {
        ThermalSleepGuard(apply: { _, _ in
            self.record("apply"); return self.snapshot(mode: .manual)
        }, restore: {
            self.record("restore")
            if self.failRestore { throw ThermalError.readbackFailed("fixture") }
            return self.snapshot(mode: .automatic)
        })
    }
    func snapshot(mode: FanHardwareMode) -> ThermalSnapshot {
        ThermalSnapshot(cpuTemperatureCelsius: 70, temperatureSensors: [],
                        fans: [FanReading(id: 0, actualRPM: 3000, minimumRPM: 2000, maximumRPM: 8000,
                                          targetRPM: 3000, mode: mode, modeKey: "F0md")])
    }
}
