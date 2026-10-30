import SwiftUI
import OrbitCore

@MainActor
final class LiveMonitoring: ObservableObject {
    @Published var snapshot: SystemSnapshot?
    @Published var samples: [SystemSnapshot] = []
    @Published var thermalSnapshot: ThermalSnapshot?
    @Published var sampleInterval = max(2, UserDefaults.standard.integer(forKey: "sampleInterval")) {
        didSet { UserDefaults.standard.set(sampleInterval, forKey: "sampleInterval") }
    }
    @Published var menuMetric = UserDefaults.standard.string(forKey: "menuMetric") ?? "CPU" {
        didSet { UserDefaults.standard.set(menuMetric, forKey: "menuMetric") }
    }
    private let monitor = SystemMonitor()
    private let thermalReader = ThermalReader()
    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    var menuLabel: String {
        guard let s = snapshot else { return "Orbit" }
        switch menuMetric {
        case "内存": return prettyBytes(s.memoryUsed)
        case "网络": return "↓ " + prettyBytes(Int64(s.networkReceivedPerSecond)) + "/s"
        case "磁盘": return prettyBytes(s.diskAvailable)
        default: return "\(Int(s.cpuUsage))%"
        }
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let sample = await monitor.sample(includeProcesses: tick % 3 == 0)
                snapshot = sample
                thermalSnapshot = await Task.detached(priority: .utility) { [thermalReader] in thermalReader.sample() }.value
                samples.append(sample)
                if samples.count > 90 { samples.removeFirst(samples.count - 90) }
                tick += 1
                try? await Task.sleep(nanoseconds: UInt64(sampleInterval) * 1_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

struct MonitoringUptime: View {
    @EnvironmentObject var monitoring: LiveMonitoring
    var body: some View { Text("持续运行 " + uptime).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }
    private var uptime: String {
        guard let value = monitoring.snapshot?.uptime else { return "—" }
        let hours = Int(value) / 3600; return "\(hours / 24) 天 \(hours % 24) 时"
    }
}
