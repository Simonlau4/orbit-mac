import XCTest
import Darwin
@testable import OrbitCore

final class ThermalTests: XCTestCase {
    func testSMCWireUsesExplicitUserClientLayoutAndNumericEndianness() {
        let request = SMCWire.request(key: "F0Tg", operation: 6, size: 4, data: [0, 0, 122, 69])
        XCTAssertEqual(request.count, 80)
        XCTAssertEqual(SMCWire.string(SMCWire.read32(request, 0)), "F0Tg")
        XCTAssertEqual(SMCWire.read32(request, 28), 4)
        XCTAssertEqual(request[42], 6)
        XCTAssertEqual(Array(request[48..<52]), [0, 0, 122, 69])
        XCTAssertEqual(SMCValue(key: "T", type: "flt ", bytes: [0, 0, 130, 66]).number, 65)
        XCTAssertEqual(SMCValue(key: "T", type: "sp78", bytes: [65, 128]).number, 65.5)
        XCTAssertEqual(SMCValue(key: "T", type: "sp78", bytes: [255, 0]).number, -1)
        XCTAssertEqual(SMCValue(key: "F", type: "fpe2", bytes: [62, 128]).number, 4000)
        XCTAssertNil(SMCValue(key: "F", type: "flt ", bytes: [0]).number)
        XCTAssertNil(SMCValue(key: "F", type: "unknown", bytes: [0]).number)
    }

    func testReadOnlyLiveSensorsArePlausibleAndNeverWrite() throws {
        let sample = ThermalReader().sample()
        XCTAssertLessThan(abs(sample.sampledAt.timeIntervalSinceNow), 5)
        for sensor in sample.temperatureSensors { XCTAssertTrue((0..<130).contains(sensor.celsius)) }
        for fan in sample.fans {
            XCTAssertGreaterThan(fan.maximumRPM, fan.minimumRPM)
            XCTAssertGreaterThanOrEqual(fan.actualRPM, 0)
            XCTAssertTrue((0...100).contains(fan.percent))
        }
        if ThermalReader.cpuBrand().contains("Apple M5 Pro") {
            XCTAssertNotNil(sample.cpuTemperatureCelsius, sample.warnings.joined(separator: "\n"))
            XCTAssertFalse(sample.fans.isEmpty, sample.warnings.joined(separator: "\n"))
        }
        XCTAssertEqual(try JSONDecoder().decode(ThermalSnapshot.self, from: JSONEncoder().encode(sample)), sample)
    }

    func testCoolingCurveReachesFullSpeedAndReturnsAfterSustainedCoolLoad() {
        var policy = FanCoolingPolicy(mode: .cool, now: 100)
        XCTAssertEqual(policy.update(snapshot: snapshot(temperature: 55), cpuUsage: 10, now: 101).targetFraction, 0.6)
        XCTAssertEqual(policy.update(snapshot: snapshot(temperature: 90), cpuUsage: 90, now: 105).targetFraction, 1)
        XCTAssertFalse(policy.update(snapshot: snapshot(temperature: 59), cpuUsage: 10, now: 110).shouldRestore)
        XCTAssertFalse(policy.update(snapshot: snapshot(temperature: 59), cpuUsage: 30, now: 170).shouldRestore)
        XCTAssertFalse(policy.update(snapshot: snapshot(temperature: 59), cpuUsage: 10, now: 171).shouldRestore)
        XCTAssertTrue(policy.update(snapshot: snapshot(temperature: 59), cpuUsage: 10, now: 231).shouldRestore)
    }

    func testMissingOrStaleTemperatureUsesFullSpeedThenRestores() {
        var policy = FanCoolingPolicy(mode: .cool, now: 100)
        let first = policy.update(snapshot: snapshot(temperature: nil), cpuUsage: 0, now: 101)
        XCTAssertFalse(first.shouldRestore)
        XCTAssertEqual(first.targetFraction, 1)
        XCTAssertTrue(policy.update(snapshot: snapshot(temperature: nil), cpuUsage: 0, now: 111).shouldRestore)
        var stalePolicy = FanCoolingPolicy(mode: .maxCool, now: 100)
        let stale = snapshot(temperature: 55, date: Date(timeIntervalSinceNow: -30))
        XCTAssertEqual(stalePolicy.update(snapshot: stale, cpuUsage: 0, now: 101).targetFraction, 1)
        XCTAssertTrue(stalePolicy.update(snapshot: stale, cpuUsage: 0, now: 111).shouldRestore)
    }

    func testBothModesHaveAHardTimeLimitAndAutomaticNeverOverrides() {
        for mode in [FanCoolingMode.cool, .maxCool] {
            var policy = FanCoolingPolicy(mode: mode, now: 0, maximumDuration: 100_000)
            XCTAssertTrue(policy.update(snapshot: snapshot(temperature: 80), cpuUsage: 100, now: 1800).shouldRestore)
        }
        var automatic = FanCoolingPolicy(mode: .automatic, now: 10)
        XCTAssertTrue(automatic.update(snapshot: snapshot(temperature: 90), cpuUsage: 100, now: 10).shouldRestore)
    }

    func testAuthorizationInvalidRangeAndOtherControllerCauseNoWrites() throws {
        let device = FakeFanDevice()
        let unauthorized = hardware(device, authorized: false)
        XCTAssertThrowsError(try unauthorized.apply(mode: .cool, targetFraction: 0.8)) { XCTAssertEqual($0 as? ThermalError, .authorizationRequired) }
        XCTAssertTrue(device.writes.isEmpty)
        let controller = hardware(device)
        for value in [Double.nan, .infinity, 0, -1, 1.1] {
            XCTAssertThrowsError(try controller.apply(mode: .cool, targetFraction: value))
        }
        XCTAssertTrue(device.writes.isEmpty)
        device.modes[1] = .manual
        XCTAssertThrowsError(try controller.apply(mode: .cool, targetFraction: 0.6)) { XCTAssertEqual($0 as? ThermalError, .manualControlInUse) }
        XCTAssertTrue(device.writes.isEmpty)
    }

    func testTargetStaysWithinHardwareRangeDoesNotSlowExistingSpeedAndRestoresAllFans() throws {
        let device = FakeFanDevice()
        device.targets[0] = 7000
        let controller = hardware(device)
        let cooled = try controller.apply(mode: .cool, targetFraction: 0.6)
        XCTAssertEqual(cooled.fans[0].targetRPM, 7000)
        XCTAssertEqual(cooled.fans[1].targetRPM, 5600)
        XCTAssertTrue(cooled.fans.allSatisfy { $0.mode == .manual && $0.targetRPM <= $0.maximumRPM })
        let max = try controller.apply(mode: .maxCool, targetFraction: 0.6)
        XCTAssertTrue(max.fans.allSatisfy { $0.targetRPM == 8000 })
        let restored = try controller.restoreAutomatic()
        XCTAssertTrue(restored.fans.allSatisfy { $0.mode == .automatic })
    }

    func testPartialWriteFailureCompensatesEveryFanAndReportsFailedRestore() throws {
        let device = FakeFanDevice()
        device.failTarget = 1
        XCTAssertThrowsError(try hardware(device).apply(mode: .cool, targetFraction: 0.6))
        XCTAssertEqual(device.modes, [.automatic, .automatic])
        XCTAssertTrue(device.writes.contains("mode0:auto"))
        XCTAssertTrue(device.writes.contains("mode1:auto"))
        device.failRestore = 1
        XCTAssertThrowsError(try hardware(device).apply(mode: .cool, targetFraction: 0.6)) {
            guard case .readbackFailed = $0 as? ThermalError else { return XCTFail("A failed restore must remain visible: \($0)") }
        }
    }

    func testSilentSMCWriteRejectionCannotBeReportedAsSuccess() {
        let device = FakeFanDevice()
        device.ignoreTarget = true
        XCTAssertThrowsError(try hardware(device).apply(mode: .maxCool, targetFraction: 1))
        XCTAssertEqual(device.modes, [.automatic, .automatic])
    }

    func testAutomaticRestoreUsesModeKeysWhenRPMSensorsBecomeUnavailable() throws {
        let device = FakeFanDevice()
        let controller = hardware(device)
        _ = try controller.apply(mode: .cool, targetFraction: 0.6)
        device.failTelemetry = true
        let restored = try controller.restoreAutomatic()
        XCTAssertEqual(device.modes, [.automatic, .automatic])
        XCTAssertEqual(restored.automaticModeVerified, true)
        XCTAssertTrue(restored.fans.isEmpty, "An unavailable RPM must not become a fabricated zero reading")
        XCTAssertTrue(restored.warnings.contains { $0.contains("转速暂时不可读") })
        let decoded = try JSONDecoder().decode(ThermalSnapshot.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(decoded.automaticModeVerified, true)
    }

    func testSleepRestoreAcceptsIndependentModeReadbackWhenRPMFails() throws {
        let device = FakeFanDevice()
        let controller = hardware(device)
        let observer = ThermalSleepGuard(apply: { try controller.apply(mode: $0, targetFraction: $1) },
                                         restore: { try controller.restoreAutomatic() })
        _ = try observer.apply(mode: .maxCool, targetFraction: 1)
        device.failTelemetry = true
        observer.prepareForSleep()
        XCTAssertTrue(observer.shouldStop)
        XCTAssertEqual(observer.didRestoreForSleep, true)
        XCTAssertNil(observer.lastSleepRestoreError)
        XCTAssertEqual(device.modes, [.automatic, .automatic])
    }

    func testForeignControllerRefusalAndAutomaticCleanupNeverWrite() throws {
        let device = FakeFanDevice()
        device.modes = [.manual, .manual]
        let controller = hardware(device)
        let observer = ThermalSleepGuard(apply: { try controller.apply(mode: $0, targetFraction: $1) },
                                         restore: { try controller.restoreAutomatic() })
        XCTAssertThrowsError(try observer.apply(mode: .cool, targetFraction: 0.6)) {
            XCTAssertEqual($0 as? ThermalError, .manualControlInUse)
        }
        XCTAssertFalse(controller.requiresAutomaticRestore)
        XCTAssertThrowsError(try observer.restoreAutomatic())
        observer.prepareForSleep()
        XCTAssertFalse(controller.requiresAutomaticRestore)
        XCTAssertEqual(device.modes, [.manual, .manual])
        XCTAssertTrue(device.writes.isEmpty, "A refusal must remain zero-write even through cleanup and sleep callbacks")
    }

    func testExplicitAutomaticRequestCanResetForeignManualMode() throws {
        let device = FakeFanDevice()
        device.modes = [.manual, .manual]
        let controller = hardware(device)
        XCTAssertFalse(controller.requiresAutomaticRestore)
        let restored = try controller.apply(mode: .automatic, targetFraction: 0)
        XCTAssertEqual(restored.automaticModeVerified, true)
        XCTAssertEqual(device.modes, [.automatic, .automatic])
        XCTAssertTrue(device.writes.contains("mode0:auto"))
        XCTAssertTrue(device.writes.contains("mode1:auto"))
        XCTAssertFalse(controller.requiresAutomaticRestore)
    }

    func testPartialWriteKeepsRecoveryOwnershipUntilVerifiedRollback() throws {
        let device = FakeFanDevice()
        device.failTarget = 1; device.failRestore = 1
        let controller = hardware(device)
        XCTAssertThrowsError(try controller.apply(mode: .cool, targetFraction: 0.6))
        XCTAssertTrue(controller.requiresAutomaticRestore)
        XCTAssertEqual(device.modes[1], .manual)
        device.failRestore = nil
        let restored = try controller.restoreAutomatic()
        XCTAssertEqual(restored.automaticModeVerified, true)
        XCTAssertFalse(controller.requiresAutomaticRestore)
        XCTAssertEqual(device.modes, [.automatic, .automatic])
    }

    func testLockGroupInheritedFromDirectoryIsNormalizedWithoutChangingIdentityOrMode() throws {
        let count = getgroups(0, nil)
        var groups = [gid_t](repeating: 0, count: max(0, Int(count)))
        guard count > 0, getgroups(count, &groups) == count, let inherited = groups.first(where: { $0 != getgid() }) else {
            throw XCTSkip("此账号没有可用于组继承 fixture 的附属组。")
        }
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directory = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-fan-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(parentFD, 0); defer { close(parentFD) }
        XCTAssertEqual(fchown(parentFD, getuid(), inherited), 0)
        let fd = openat(parentFD, "fan.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var before = stat(); XCTAssertEqual(fstat(fd, &before), 0)
        XCTAssertEqual(before.st_gid, inherited, "Darwin inherits the containing directory's group")
        XCTAssertTrue(FanLockOwnership.normalize(fd, owner: getuid(), group: getgid()))
        var after = stat(); XCTAssertEqual(fstat(fd, &after), 0)
        XCTAssertEqual(after.st_gid, getgid()); XCTAssertEqual(after.st_uid, getuid())
        XCTAssertEqual(after.st_mode & 0o7777, 0o600)
        XCTAssertEqual(after.st_ino, before.st_ino); XCTAssertEqual(after.st_dev, before.st_dev)
    }

    func testUnsafeLockDescriptorsAreRejectedBeforeOwnershipChanges() throws {
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directory = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-fan-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fan.lock")
        let fd = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var called = false
        let change: (Int32, uid_t, gid_t) -> Int32 = { _, _, _ in called = true; return 0 }
        XCTAssertFalse(FanLockOwnership.normalize(fd, owner: getuid() == 0 ? 1 : 0, group: 0, changeOwner: change))
        XCTAssertFalse(called)
        XCTAssertEqual(fchmod(fd, 0o644), 0)
        XCTAssertFalse(FanLockOwnership.normalize(fd, owner: getuid(), group: 0, changeOwner: change))
        XCTAssertFalse(called)
        XCTAssertEqual(fchmod(fd, 0o600), 0)
        let alias = directory.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: path, to: alias)
        XCTAssertFalse(FanLockOwnership.normalize(fd, owner: getuid(), group: 0, changeOwner: change))
        XCTAssertFalse(called)
        try FileManager.default.removeItem(at: alias)
        let symbolic = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: path)
        let refused = open(symbolic.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertEqual(refused, -1)
        if refused >= 0 { close(refused) }
        XCTAssertFalse(FanLockOwnership.normalize(refused, owner: getuid(), group: 0, changeOwner: change))
        XCTAssertFalse(called)
    }

    func testLockNormalizationRequiresSuccessfulOwnershipReadback() throws {
        var actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &actual) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directory = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-fan-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = open(directory.appendingPathComponent("fan.lock").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var before = stat(); XCTAssertEqual(fstat(fd, &before), 0)
        let differentGroup: gid_t = before.st_gid == 0 ? 1 : 0
        XCTAssertFalse(FanLockOwnership.normalize(fd, owner: getuid(), group: differentGroup, changeOwner: { _, _, _ in -1 }))
        XCTAssertFalse(FanLockOwnership.normalize(fd, owner: getuid(), group: differentGroup, changeOwner: { _, _, _ in 0 }))
        var after = stat(); XCTAssertEqual(fstat(fd, &after), 0)
        XCTAssertEqual(after.st_gid, before.st_gid)
        XCTAssertEqual(after.st_mode & 0o7777, 0o600)
    }

    func testM5TargetEncodingMatchesLiveFloatBytesAndModeEncoding() throws {
        let bytes = try SMCWire.numberBytes(2317, type: "flt ", size: 4)
        XCTAssertEqual(bytes, [0, 208, 16, 69]) // The exact read-only F0Tg bytes on this M5 Pro.
        XCTAssertEqual(SMCValue(key: "F0Tg", type: "flt ", bytes: bytes).number, 2317)
        let fractional = try SMCWire.numberBytes(5622.4, type: "flt ", size: 4)
        XCTAssertEqual(try XCTUnwrap(SMCValue(key: "F0Tg", type: "flt ", bytes: fractional).number), 5622.4, accuracy: 0.001)
        XCTAssertEqual(try SMCWire.numberBytes(1, type: "ui8 ", size: 1), [1])
        XCTAssertEqual(try SMCWire.numberBytes(0, type: "ui8 ", size: 1), [0])
        XCTAssertThrowsError(try SMCWire.numberBytes(5622.4, type: "flt ", size: 2))
    }

    func testDelayedTargetReadbackWaitsWithoutRepeatingWrites() throws {
        let device = FakeFanDevice()
        device.targetDelayReads = 3
        let controller = hardware(device)
        let result = try controller.apply(mode: .cool, targetFraction: 0.6)
        XCTAssertTrue(result.fans.allSatisfy { $0.mode == .manual && abs($0.targetRPM - 5600) < 0.1 })
        XCTAssertEqual(device.writes.filter { $0.hasPrefix("target") }.count, 2)
        XCTAssertEqual(device.writes.filter { $0.hasSuffix(":manual") }.count, 2)
    }

    func testModeTakeoverReportsObservedStateWithoutReassertingManualControl() {
        let device = FakeFanDevice()
        device.autoAfterTarget = true
        let controller = hardware(device)
        XCTAssertThrowsError(try controller.apply(mode: .cool, targetFraction: 0.6)) {
            let message = $0.localizedDescription
            XCTAssertTrue(message.contains("5600.0"), message)
            XCTAssertTrue(message.contains("automatic"), message)
            XCTAssertTrue(message.contains("F0md"), message)
        }
        XCTAssertEqual(device.writes.filter { $0.hasSuffix(":manual") }.count, 1)
        XCTAssertEqual(device.writes.filter { $0.hasPrefix("target") }.count, 1)
        XCTAssertEqual(device.modes, [.automatic, .automatic])
        XCTAssertFalse(controller.requiresAutomaticRestore)
    }

    private func snapshot(temperature: Double?, date: Date = Date()) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date, cpuTemperatureCelsius: temperature, temperatureSensors: [], fans: [])
    }
    private func hardware(_ device: FakeFanDevice, authorized: Bool = true) -> ThermalFanHardware {
        ThermalFanHardware(device: device, readSnapshot: {
            ThermalSnapshot(cpuTemperatureCelsius: 70, temperatureSensors: [], fans: (try? device.fans()) ?? [])
        }, isAuthorized: { authorized })
    }
}

private final class FakeFanDevice: SMCFanDevice, @unchecked Sendable {
    var modes: [FanHardwareMode] = [.automatic, .automatic]
    var targets: [Double] = [3000, 3000]
    var writes: [String] = []
    var failTarget: Int?
    var failRestore: Int?
    var ignoreTarget = false
    var failTelemetry = false
    var targetDelayReads = 0
    var autoAfterTarget = false
    private var pendingTargets: [Int: (rpm: Double, reads: Int)] = [:]
    func number(_ key: String) throws -> Double { throw ThermalError.unavailable(key) }
    func fans() throws -> [FanReading] {
        if failTelemetry { throw ThermalError.unavailable("fixture RPM") }
        for (id, pending) in pendingTargets {
            if pending.reads <= 1 { targets[id] = pending.rpm; pendingTargets.removeValue(forKey: id) }
            else { pendingTargets[id] = (pending.rpm, pending.reads - 1) }
        }
        return (0..<2).map { FanReading(id: $0, actualRPM: 3000, minimumRPM: 2000, maximumRPM: 8000,
                                targetRPM: targets[$0], mode: modes[$0], modeKey: "F\($0)md") }
    }
    func fanModes() throws -> [SMCFanMode] {
        (0..<2).map { SMCFanMode(id: $0, modeKey: "F\($0)md", mode: modes[$0]) }
    }
    func writeFanTarget(id: Int, rpm: Double) throws {
        writes.append("target\(id):\(rpm)")
        if id == failTarget { throw ThermalError.hardwareRejected("fixture") }
        if !ignoreTarget {
            if targetDelayReads > 0 { pendingTargets[id] = (rpm, targetDelayReads) }
            else { targets[id] = rpm }
        }
        if autoAfterTarget { modes[id] = .automatic }
    }
    func writeFanMode(id: Int, modeKey: String, manual: Bool) throws {
        writes.append("mode\(id):\(manual ? "manual" : "auto")")
        if !manual && id == failRestore { throw ThermalError.hardwareRejected("fixture restore") }
        modes[id] = manual ? .manual : .automatic
    }
    func writeTestMode(_ enabled: Bool) throws { writes.append("test:\(enabled)") }
}
