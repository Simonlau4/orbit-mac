import Foundation
import OrbitCore

@MainActor
final class FanControlClient {
    private var heartbeat: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var leaseURL: URL?
    private var leaseID: UUID?
    private(set) var mode: FanCoolingMode = .automatic
    private(set) var lastRestoreConfirmed = true
    var isRunning: Bool { operation != nil }
    var onFinish: ((String, Bool) -> Void)?

    func start(_ mode: FanCoolingMode) throws {
        if operation != nil {
            self.mode = mode
            try renew()
            return
        }
        let launcher = try PrivilegedToolLauncher(.fan)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit/FanControl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let id = UUID()
        leaseID = id; leaseURL = directory.appendingPathComponent(id.uuidString + ".json"); self.mode = mode
        try renew()
        lastRestoreConfirmed = false
        let command = try launcher.command(arguments: ["--client", String(ProcessInfo.processInfo.processIdentifier), "--lease", leaseURL!.path], timeout: 1900)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                do { try self.renew() } catch { self.heartbeat?.cancel(); return }
            }
        }
        operation = Task { [weak self] in
            let result = await MaintenanceService.execute(command)
            guard let self else { return }
            self.heartbeat?.cancel(); self.heartbeat = nil; self.operation = nil; self.mode = .automatic
            let report = result.output.split(separator: "\n").reversed().compactMap { line in
                try? JSONDecoder().decode(FanControlReport.self, from: Data(line.utf8))
            }.first
            self.lastRestoreConfirmed = report?.restored == true || ThermalReader().sample().automaticModeVerified == true
            let message = report?.message ?? (result.output.contains("(-128)") ? "管理员认证已取消，风扇未更改。" : result.output.isEmpty ? "降温控制已结束，请核对风扇自动模式。" : String(result.output.prefix(600)))
            self.onFinish?(message, report?.restored == true)
        }
    }

    /// The elevated process observes automatic mode or the ten-second lease expiry itself.
    func stop() {
        mode = .automatic
        try? renew()
        heartbeat?.cancel(); heartbeat = nil
    }
    func confirmAutomaticBeforeExit() async -> Bool {
        stop()
        let reader = ThermalReader()
        for _ in 0..<60 {
            if reader.sample().automaticModeVerified == true { lastRestoreConfirmed = true; return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
    private func renew() throws {
        guard let leaseURL, let leaseID else { return }
        try JSONEncoder().encode(FanControlLease(id: leaseID, mode: mode)).write(to: leaseURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leaseURL.path)
    }
}
