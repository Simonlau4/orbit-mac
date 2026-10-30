import XCTest
@testable import OrbitCore

final class SystemMonitorTests: XCTestCase {
    func testRealSystemSampleAndNetworkBaseline() async throws {
        let monitor = SystemMonitor()
        let first = await monitor.sample(includeProcesses: false)
        XCTAssertGreaterThan(first.memoryTotal, 0)
        XCTAssertGreaterThan(first.memoryUsed, 0)
        XCTAssertLessThanOrEqual(first.memoryUsed, first.memoryTotal)
        XCTAssertGreaterThan(first.diskTotal, 0)
        XCTAssertLessThanOrEqual(first.diskAvailable, first.diskTotal)
        XCTAssertGreaterThan(first.uptime, 0)
        XCTAssertGreaterThan(first.cpuCount, 0)
        XCTAssertTrue((0...100).contains(first.cpuUsage))
        XCTAssertEqual(first.networkReceivedPerSecond, 0)
        XCTAssertEqual(first.networkSentPerSecond, 0)
        XCTAssertTrue(first.processes.isEmpty)
        XCTAssertFalse(first.thermalState.isEmpty)
        XCTAssertLessThan(abs(first.sampledAt.timeIntervalSinceNow), 5)

        try await Task.sleep(nanoseconds: 100_000_000)
        let second = await monitor.sample(includeProcesses: false)
        XCTAssertTrue((0...100).contains(second.cpuUsage))
        XCTAssertTrue(second.networkReceivedPerSecond.isFinite)
        XCTAssertGreaterThanOrEqual(second.networkReceivedPerSecond, 0)
        XCTAssertTrue(second.networkSentPerSecond.isFinite)
        XCTAssertGreaterThanOrEqual(second.networkSentPerSecond, 0)
        XCTAssertGreaterThanOrEqual(second.uptime, first.uptime)
        XCTAssertFalse(second.warnings.contains { $0.contains("首次采样") })
    }

    func testRealProcessesAndCodableRoundTrip() async throws {
        let monitor = SystemMonitor()
        let snapshot = await monitor.sample()
        XCTAssertFalse(snapshot.processes.isEmpty, snapshot.warnings.joined(separator: "\n"))
        for process in snapshot.processes {
            XCTAssertGreaterThan(process.pid, 0)
            XCTAssertFalse(process.name.isEmpty)
            XCTAssertTrue(process.cpuPercent.isFinite)
            XCTAssertGreaterThanOrEqual(process.cpuPercent, 0)
            XCTAssertEqual(process.id, process.pid)
        }
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(SystemSnapshot.self, from: encoded), snapshot)
        let fastRefresh = await monitor.sample(includeProcesses: false)
        XCTAssertEqual(fastRefresh.processes, snapshot.processes)
    }

    func testCPUDeltaUsesIdleAndHandlesCounterWrap() {
        XCTAssertEqual(SystemMonitor.cpuUsage(previous: [0, 0, 0, 0], current: [10, 10, 80, 0]), 20, accuracy: 0.0001)
        XCTAssertEqual(SystemMonitor.cpuUsage(previous: [3, 4, 5, 0], current: [3, 4, 5, 0]), 0)
        XCTAssertEqual(SystemMonitor.cpuUsage(previous: [UInt32.max - 4, 0, 0, 0], current: [5, 0, 10, 0]), 50, accuracy: 0.0001)
    }

    func testLiveHealthFieldsHaveValidRangesAndDiskBaseline() async throws {
        let monitor = SystemMonitor()
        let first = await monitor.sample(includeProcesses: false)
        XCTAssertNil(first.diskReadBytesPerSecond)
        XCTAssertNil(first.diskWriteBytesPerSecond)
        if let battery = first.battery {
            if let charge = battery.chargePercent { XCTAssertTrue((0...100).contains(charge)) }
            if let health = battery.healthPercent { XCTAssertTrue((0...100).contains(health)) }
            if let cycles = battery.cycleCount { XCTAssertGreaterThanOrEqual(cycles, 0) }
            XCTAssertFalse(battery.source.isEmpty)
        }
        if let averages = first.loadAverages {
            XCTAssertEqual(averages.count, 3)
            XCTAssertTrue(averages.allSatisfy { $0.isFinite && $0 >= 0 })
        }
        if let temperature = first.temperatureCelsius {
            XCTAssertTrue((0..<130).contains(temperature))
            XCTAssertFalse(first.temperatureSource?.isEmpty ?? true)
        } else { XCTAssertFalse(first.temperatureUnavailableReason?.isEmpty ?? true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let next = await monitor.sample(includeProcesses: false)
        if let read = next.diskReadBytesPerSecond { XCTAssertTrue(read.isFinite && read >= 0) }
        if let write = next.diskWriteBytesPerSecond { XCTAssertTrue(write.isFinite && write >= 0) }
    }

    func testLegacySnapshotJSONWithoutNewOptionalFieldsStillDecodes() async throws {
        let current = await SystemMonitor().sample(includeProcesses: false)
        let data = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["battery", "diskReadBytesPerSecond", "diskWriteBytesPerSecond", "primaryInterface", "localIPv4Address", "loadAverages", "temperatureCelsius", "temperatureSource", "temperatureUnavailableReason"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(SystemSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.cpuUsage, current.cpuUsage)
        XCTAssertNil(legacy.battery)
        XCTAssertNil(legacy.loadAverages)
    }
}
