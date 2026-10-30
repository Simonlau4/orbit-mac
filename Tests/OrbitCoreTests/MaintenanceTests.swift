import XCTest
@testable import OrbitCore

final class MaintenanceTests: XCTestCase {
    func testTaskRoutingUsesFixedArgumentsAndMarksAdministratorTask() {
        let dns = MaintenanceService.command(for: .dnsCache)
        XCTAssertEqual(dns.executable, "/usr/bin/dscacheutil")
        XCTAssertEqual(dns.arguments, ["-flushcache"])
        XCTAssertFalse(MaintenanceTask.dnsCache.requiresAdmin)
        XCTAssertEqual(MaintenanceService.command(for: .quickLookCache).arguments, ["-r", "cache"])
        let systemDNS = MaintenanceService.command(for: .systemDNS)
        XCTAssertTrue(MaintenanceTask.systemDNS.requiresAdmin)
        XCTAssertEqual(systemDNS.executable, "/usr/bin/osascript")
        XCTAssertTrue(systemDNS.arguments[1].contains("with administrator privileges"))
        XCTAssertTrue(systemDNS.arguments[1].contains("-HUP mDNSResponder"))
        XCTAssertFalse(systemDNS.arguments[1].contains("sudo"))
    }

    func testInjectedRunnerReportsSuccessFailureTimeoutAndCancellation() async {
        let success = MaintenanceService(runner: { command in
            XCTAssertEqual(command.executable, "/usr/bin/qlmanage")
            return MaintenanceCommandResult(exitCode: 0, output: "fixture success")
        })
        let done = await success.run(.quickLookCache)
        XCTAssertEqual(done.status, .success)
        XCTAssertEqual(done.output, "fixture success")
        XCTAssertGreaterThanOrEqual(done.elapsedSeconds, 0)

        let failure = await MaintenanceService(runner: { _ in MaintenanceCommandResult(exitCode: 2, output: "fixture denied") }).run(.dnsCache)
        XCTAssertEqual(failure.status, .failed)
        XCTAssertEqual(failure.message, "fixture denied")
        let timeout = await MaintenanceService(runner: { _ in MaintenanceCommandResult(exitCode: -1, output: "", timedOut: true) }).run(.dnsCache)
        XCTAssertEqual(timeout.status, .timedOut)
        let cancel = await MaintenanceService(runner: { _ in MaintenanceCommandResult(exitCode: 1, output: "execution error: User canceled. (-128)") }).run(.systemDNS)
        XCTAssertEqual(cancel.status, .cancelled)
    }

    func testActualExecutorCapturesOutputAndExitFailureWithoutMaintenance() async {
        // Harmless executables do not change caches, DNS or system settings.
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/printf", arguments: ["fixture-output"], timeoutSeconds: 1))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "fixture-output")
        XCTAssertFalse(result.timedOut)
        let failed = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/false", arguments: [], timeoutSeconds: 1))
        XCTAssertNotEqual(failed.exitCode, 0)
    }

    func testActualExecutorTimeoutAndCancellationTerminateOwnedProcess() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let timeout = await MaintenanceService.execute(MaintenanceCommand(executable: "/bin/sleep", arguments: ["5"], timeoutSeconds: 0.05))
        XCTAssertTrue(timeout.timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        // A fixture that ignores SIGTERM still has to be killed promptly on cancellation.
        let task = Task { await MaintenanceService.execute(MaintenanceCommand(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 5"], timeoutSeconds: 10)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertFalse(cancelled.timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 2)
    }

    func testOutputIsBoundedAndMissingExecutableFails() async {
        let huge = String(repeating: "x", count: 50_000)
        let result = await MaintenanceService(runner: { _ in MaintenanceCommandResult(exitCode: 0, output: huge) }).run(.dnsCache)
        XCTAssertEqual(result.output.count, 16_384)
        let missing = await MaintenanceService.execute(MaintenanceCommand(executable: "/orbit-nonexistent-fixture", arguments: [], timeoutSeconds: 1))
        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertFalse(missing.output.isEmpty)
    }
}
