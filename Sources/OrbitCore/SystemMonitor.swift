import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

public struct BatteryStatus: Codable, Sendable, Equatable {
    public let chargePercent: Double?
    public let isCharging: Bool?
    public let externalPowerConnected: Bool?
    public let cycleCount: Int?
    public let healthPercent: Double?
    public let source: String
}

public struct ProcessSample: Codable, Identifiable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

public struct SystemSnapshot: Codable, Sendable, Equatable {
    public var sampledAt: Date
    public var cpuUsage: Double
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var swapUsed: UInt64
    public var diskTotal: UInt64
    public var diskAvailable: UInt64
    public var networkReceivedPerSecond: Double
    public var networkSentPerSecond: Double
    public var uptime: TimeInterval
    public var thermalState: String
    public var cpuCount: Int
    public var processes: [ProcessSample]
    public var warnings: [String]
    public var battery: BatteryStatus?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var primaryInterface: String?
    public var localIPv4Address: String?
    public var loadAverages: [Double]?
    public var temperatureCelsius: Double?
    public var temperatureSource: String?
    public var temperatureUnavailableReason: String?

    public init(sampledAt: Date, cpuUsage: Double, memoryUsed: UInt64,
                memoryTotal: UInt64, swapUsed: UInt64, diskTotal: UInt64,
                diskAvailable: UInt64, networkReceivedPerSecond: Double,
                networkSentPerSecond: Double, uptime: TimeInterval,
                thermalState: String, cpuCount: Int, processes: [ProcessSample],
                warnings: [String] = [], battery: BatteryStatus? = nil,
                diskReadBytesPerSecond: Double? = nil, diskWriteBytesPerSecond: Double? = nil,
                primaryInterface: String? = nil, localIPv4Address: String? = nil,
                loadAverages: [Double]? = nil, temperatureCelsius: Double? = nil,
                temperatureSource: String? = nil, temperatureUnavailableReason: String? = nil) {
        self.sampledAt = sampledAt
        self.cpuUsage = cpuUsage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.swapUsed = swapUsed
        self.diskTotal = diskTotal
        self.diskAvailable = diskAvailable
        self.networkReceivedPerSecond = networkReceivedPerSecond
        self.networkSentPerSecond = networkSentPerSecond
        self.uptime = uptime
        self.thermalState = thermalState
        self.cpuCount = cpuCount
        self.processes = processes
        self.warnings = warnings
        self.battery = battery
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.primaryInterface = primaryInterface
        self.localIPv4Address = localIPv4Address
        self.loadAverages = loadAverages
        self.temperatureCelsius = temperatureCelsius
        self.temperatureSource = temperatureSource
        self.temperatureUnavailableReason = temperatureUnavailableReason
    }
}

public actor SystemMonitor {
    private let thermalReader = ThermalReader()
    private let host = mach_host_self()
    private var previousCPU: [UInt32]?
    private var previousNetwork: (time: TimeInterval, values: [String: NetworkCounter])?
    private var previousProcesses: [ProcessSample] = []
    private var previousDiskIO: (time: TimeInterval, values: [UInt64: DiskCounter])?

    public init() {}

    deinit { mach_port_deallocate(mach_task_self_, host) }

    public func sample(includeProcesses: Bool = true) -> SystemSnapshot {
        var warnings: [String] = []
        // A short first measurement reports interval activity, not the average since boot.
        if previousCPU == nil {
            previousCPU = readCPU(warnings: &warnings)
            if previousCPU != nil { Thread.sleep(forTimeInterval: 0.12) }
        }
        let currentCPU = readCPU(warnings: &warnings)
        let cpuUsage: Double
        if let old = previousCPU, let current = currentCPU {
            cpuUsage = Self.cpuUsage(previous: old, current: current)
        } else {
            cpuUsage = 0
        }
        if let currentCPU { previousCPU = currentCPU }

        let memoryTotal = ProcessInfo.processInfo.physicalMemory
        let memoryUsed = readMemory(total: memoryTotal, warnings: &warnings)
        let swapUsed = readSwap(warnings: &warnings)
        let disk = readDisk(warnings: &warnings)
        let network = readNetwork(warnings: &warnings)
        let now = ProcessInfo.processInfo.systemUptime
        var received: Double = 0
        var sent: Double = 0
        if let previousNetwork, now > previousNetwork.time {
            let duration = now - previousNetwork.time
            for (name, counter) in network {
                guard let old = previousNetwork.values[name] else { continue }
                guard counter.lastChange.tv_sec == old.lastChange.tv_sec,
                      counter.lastChange.tv_usec == old.lastChange.tv_usec else { continue }
                received += Double(counter.received &- old.received) / duration
                sent += Double(counter.sent &- old.sent) / duration
            }
        } else if !network.isEmpty {
            warnings.append("网络首次采样正在建立基线；速率从下次刷新起显示。")
        }
        previousNetwork = (now, network)
        let diskIO = readDiskIO()
        var readRate: Double?
        var writeRate: Double?
        if let diskIO, let previousDiskIO, now > previousDiskIO.time {
            let elapsed = now - previousDiskIO.time
            var read: Double = 0
            var write: Double = 0
            for (identifier, counter) in diskIO {
                guard let old = previousDiskIO.values[identifier], counter.read >= old.read, counter.write >= old.write else { continue }
                read += Double(counter.read - old.read) / elapsed
                write += Double(counter.write - old.write) / elapsed
            }
            readRate = read
            writeRate = write
        }
        if let diskIO { previousDiskIO = (now, diskIO) }
        let networkIdentity = readNetworkIdentity()
        if includeProcesses {
            let processes = readProcesses(warnings: &warnings)
            if !processes.isEmpty { previousProcesses = processes }
        }

        let thermal = thermalReader.sample()
        return SystemSnapshot(
            sampledAt: Date(), cpuUsage: cpuUsage, memoryUsed: memoryUsed,
            memoryTotal: memoryTotal, swapUsed: swapUsed, diskTotal: disk.total,
            diskAvailable: disk.available, networkReceivedPerSecond: received,
            networkSentPerSecond: sent, uptime: now,
            thermalState: thermalDescription,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            processes: previousProcesses,
            warnings: warnings, battery: readBattery(),
            diskReadBytesPerSecond: readRate, diskWriteBytesPerSecond: writeRate,
            primaryInterface: networkIdentity.interface, localIPv4Address: networkIdentity.address,
            loadAverages: readLoadAverages(),
            temperatureCelsius: thermal.cpuTemperatureCelsius, temperatureSource: thermal.temperatureSource,
            temperatureUnavailableReason: thermal.cpuTemperatureCelsius == nil ? thermal.warnings.joined(separator: "；") : nil
        )
    }

    private func readBattery() -> BatteryStatus? {
        var charge: Double?
        var charging: Bool?
        var external: Bool?
        var cycles: Int?
        var health: Double?
        var source = "IOPowerSources"
        if let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(information)?.takeRetainedValue() as? [CFTypeRef] {
            for powerSource in sources {
                guard let values = IOPSGetPowerSourceDescription(information, powerSource)?.takeUnretainedValue() as? [String: Any] else { continue }
                guard values["Transport Type"] as? String == "Internal" || values["Type"] as? String == "InternalBattery" else { continue }
                if let current = values["Current Capacity"] as? NSNumber,
                   let maximum = values["Max Capacity"] as? NSNumber, maximum.doubleValue > 0 {
                    charge = min(100, max(0, current.doubleValue / maximum.doubleValue * 100))
                }
                charging = (values["Is Charging"] as? NSNumber)?.boolValue
                if let state = values["Power Source State"] as? String { external = state == "AC Power" }
                if charge != nil { break }
            }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            source += " / AppleSmartBattery"
            func number(_ key: String) -> NSNumber? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            }
            if charge == nil, let current = number("CurrentCapacity"), let maximum = number("MaxCapacity"), maximum.doubleValue > 0 {
                charge = min(100, max(0, current.doubleValue / maximum.doubleValue * 100))
            }
            charging = number("IsCharging")?.boolValue ?? charging
            external = number("ExternalConnected")?.boolValue ?? external
            if let count = number("CycleCount")?.intValue, count >= 0 { cycles = count }
            if let maximum = number("NominalChargeCapacity")?.doubleValue,
               let design = number("DesignCapacity")?.doubleValue, maximum > 0, design > 0 {
                health = min(100, max(0, maximum / design * 100))
            }
        }
        guard charge != nil || charging != nil || external != nil || cycles != nil else { return nil }
        return BatteryStatus(chargePercent: charge, isCharging: charging, externalPowerConnected: external,
                             cycleCount: cycles, healthPercent: health, source: source)
    }

    private struct DiskCounter { let read: UInt64; let write: UInt64 }

    private func readDiskIO() -> [UInt64: DiskCounter]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: DiskCounter] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var identifier: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS,
                  result[identifier] == nil, !isVirtualDisk(service),
                  let statistics = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let read = statistics["Bytes (Read)"] as? NSNumber,
                  let write = statistics["Bytes (Write)"] as? NSNumber else { continue }
            result[identifier] = DiskCounter(read: read.uint64Value, write: write.uint64Value)
        }
        return result.isEmpty ? nil : result
    }

    private func isVirtualDisk(_ service: io_registry_entry_t) -> Bool {
        var current = service
        var ownsCurrent = false
        defer { if ownsCurrent { IOObjectRelease(current) } }
        for _ in 0..<8 {
            let name = (IOObjectCopyClass(current)?.takeRetainedValue() as String?)?.lowercased() ?? ""
            if name.contains("hdix") || name.contains("diskimage") || name.contains("virtual") { return true }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true
        }
        return false
    }

    private func readNetworkIdentity() -> (interface: String?, address: String?) {
        let store = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let routed = store?["PrimaryInterface"] as? String
        let primary = routed?.hasPrefix("en") == true ? routed : nil
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return (primary, nil) }
        defer { freeifaddrs(first) }
        var cursor = first
        var fallback: (String, String)?
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"), interface.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if name == primary { return (name, value) }
            if fallback == nil { fallback = (name, value) }
        }
        return primary == nil ? (fallback?.0, fallback?.1) : (primary, nil)
    }

    private func readLoadAverages() -> [Double]? {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : nil
    }

    static func cpuUsage(previous: [UInt32], current: [UInt32]) -> Double {
        guard previous.count == 4, current.count == 4 else { return 0 }
        let deltas = zip(previous, current).map { UInt64($1 &- $0) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return 0 }
        return min(100, max(0, Double(total - deltas[Int(CPU_STATE_IDLE)]) / Double(total) * 100))
    }

    private func readCPU(warnings: inout [String]) -> [UInt32]? {
        var value = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            warnings.append("CPU 采样不可用（系统错误 \(result)）。")
            return nil
        }
        return [value.cpu_ticks.0, value.cpu_ticks.1, value.cpu_ticks.2, value.cpu_ticks.3]
    }

    private func readMemory(total: UInt64, warnings: inout [String]) -> UInt64 {
        var value = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else {
            warnings.append("内存采样不可用（系统错误 \(result)）。")
            return 0
        }
        // Active, wired and compressed physical pages; inactive/file cache is reclaimable.
        let pages = UInt64(value.active_count) + UInt64(value.wire_count) + UInt64(value.compressor_page_count)
        return min(total, pages * UInt64(pageSize))
    }

    private func readSwap(warnings: inout [String]) -> UInt64 {
        var value = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &value, &size, nil, 0) == 0 else {
            warnings.append("交换内存采样不可用：\(String(cString: strerror(errno)))。")
            return 0
        }
        return value.xsu_used
    }

    private func readDisk(warnings: inout [String]) -> (total: UInt64, available: UInt64) {
        do {
            let values = try FileManager.default.homeDirectoryForCurrentUser.resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
            )
            if let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity {
                return (UInt64(max(0, total)), UInt64(max(0, available)))
            }
            warnings.append("磁盘容量未由系统返回。")
        } catch {
            warnings.append("磁盘容量读取失败：\(error.localizedDescription)")
        }
        return (0, 0)
    }

    private struct NetworkCounter {
        var received: UInt32
        var sent: UInt32
        var lastChange: timeval32
    }

    private func readNetwork(warnings: inout [String]) -> [String: NetworkCounter] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            warnings.append("网络采样不可用：\(String(cString: strerror(errno)))。")
            return [:]
        }
        defer { freeifaddrs(first) }
        var result: [String: NetworkCounter] = [:]
        var cursor = first
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"), interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            result[name] = NetworkCounter(received: data.ifi_ibytes, sent: data.ifi_obytes, lastChange: data.ifi_lastchange)
        }
        if result.isEmpty { warnings.append("未检测到活动的物理网络接口；网络速率为 0。") }
        return result
    }

    private var thermalDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "轻度压力"
        case .serious: return "较高压力"
        case .critical: return "严重压力"
        @unknown default: return "未知"
        }
    }

    private func readProcesses(warnings: inout [String]) -> [ProcessSample] {
        let process = Process()
        let output = Pipe()
        let exited = DispatchSemaphore(value: 0)
        let readFinished = DispatchGroup()
        let buffer = MonitorOutputBuffer()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            warnings.append("进程列表读取失败：\(error.localizedDescription)")
            return []
        }
        readFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            buffer.store(output.fileHandleForReading.readDataToEndOfFile())
            readFinished.leave()
        }
        var completed = exited.wait(timeout: .now() + 1.5) == .success
        if !completed {
            process.terminate()
            completed = exited.wait(timeout: .now() + 0.2) == .success
            if !completed, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                completed = exited.wait(timeout: .now() + 0.2) == .success
            }
            warnings.append("进程采样超时，本次未返回进程列表。")
            return []
        }
        guard completed, process.terminationStatus == 0,
              readFinished.wait(timeout: .now() + 0.3) == .success else {
            warnings.append("进程采样未完成，本次未返回进程列表。")
            return []
        }
        let text = String(decoding: buffer.data(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line -> ProcessSample? in
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 4, let pid = Int32(parts[0]), pid > 0,
                  let cpu = Double(parts[1]), cpu.isFinite, cpu >= 0,
                  let memoryKB = UInt64(parts[2]), memoryKB <= UInt64.max / 1024 else { return nil }
            let name = URL(fileURLWithPath: String(parts[3])).lastPathComponent
            return ProcessSample(pid: pid, name: name, cpuPercent: cpu, memoryBytes: memoryKB * 1024)
        }.sorted {
            $0.cpuPercent == $1.cpuPercent ? $0.memoryBytes > $1.memoryBytes : $0.cpuPercent > $1.cpuPercent
        }.prefix(30).map { $0 }
    }
}

private final class MonitorOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func store(_ data: Data) { lock.lock(); defer { lock.unlock() }; value = data }
    func data() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}
