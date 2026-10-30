import Foundation
import Darwin
import IOKit

public enum FanCoolingMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, cool, maxCool
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: return "自动"; case .cool: return "降温"; case .maxCool: return "强冷" }
    }
}

public enum FanHardwareMode: String, Codable, Sendable { case automatic, manual, system, unknown }

public struct TemperatureSensor: Codable, Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let group: String
    public let celsius: Double
    public var id: String { key }
    public init(key: String, name: String, group: String, celsius: Double) {
        self.key = key; self.name = name; self.group = group; self.celsius = celsius
    }
}

public struct FanReading: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double
    public let mode: FanHardwareMode
    public let modeKey: String
    public var percent: Double { maximumRPM > 0 ? min(100, max(0, actualRPM / maximumRPM * 100)) : 0 }
    public init(id: Int, actualRPM: Double, minimumRPM: Double, maximumRPM: Double,
                targetRPM: Double, mode: FanHardwareMode, modeKey: String) {
        self.id = id; self.actualRPM = actualRPM; self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM; self.targetRPM = targetRPM; self.mode = mode; self.modeKey = modeKey
    }
}

public struct ThermalSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let cpuTemperatureCelsius: Double?
    public let temperatureSensors: [TemperatureSensor]
    public let fans: [FanReading]
    public let warnings: [String]
    /// Separately verified mode state remains meaningful when an RPM sensor is temporarily unreadable.
    public private(set) var automaticModeVerified: Bool?
    public var temperatureSource: String? {
        let count = temperatureSensors.filter { $0.group == "CPU" }.count
        return count > 0 ? "AppleSMC · \(count) 个 CPU 传感器平均" : nil
    }
    public init(sampledAt: Date = Date(), cpuTemperatureCelsius: Double?, temperatureSensors: [TemperatureSensor],
                fans: [FanReading], warnings: [String] = []) {
        self.sampledAt = sampledAt; self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.temperatureSensors = temperatureSensors; self.fans = fans; self.warnings = warnings
        automaticModeVerified = fans.isEmpty || fans.contains(where: { $0.mode == .unknown })
            ? nil : fans.allSatisfy({ $0.mode == .automatic || $0.mode == .system })
    }
    func confirmingAutomaticMode() -> ThermalSnapshot {
        var copy = ThermalSnapshot(sampledAt: sampledAt, cpuTemperatureCelsius: cpuTemperatureCelsius,
            temperatureSensors: temperatureSensors, fans: fans,
            warnings: warnings + (fans.isEmpty ? ["风扇自动模式已独立读回确认；转速暂时不可读。"] : []))
        copy.automaticModeVerified = true
        return copy
    }
}

public enum ThermalError: LocalizedError, Equatable {
    case unavailable(String), authorizationRequired, invalidCommand, invalidFanLimits(Int), manualControlInUse
    case hardwareRejected(String), readbackFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "无法读取温控硬件：\(detail)"
        case .authorizationRequired: return "风扇控制需要 macOS 管理员认证。"
        case .invalidCommand: return "风扇指令超出允许范围。"
        case .invalidFanLimits(let id): return "风扇 \(id + 1) 的硬件转速范围无效。"
        case .manualControlInUse: return "其他程序正在控制风扇，请先将其交回系统自动调节。"
        case .hardwareRejected(let detail): return "硬件未接受风扇指令：\(detail)"
        case .readbackFailed(let detail): return "无法确认风扇状态：\(detail)"
        }
    }
}

/// The root helper opens its one fixed lock path with O_NOFOLLOW. Darwin can inherit the
/// directory's daemon group; normalize that FD only after proving it is a private root file.
public enum FanLockOwnership {
    public static func normalizeRootLock(_ fd: Int32) -> Bool {
        guard geteuid() == 0 else { return false }
        return normalize(fd, owner: 0, group: 0)
    }
    static func normalize(_ fd: Int32, owner: uid_t, group: gid_t,
                          changeOwner: (Int32, uid_t, gid_t) -> Int32 = { fchown($0, $1, $2) }) -> Bool {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == owner, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_mode & 0o7777 == 0o600 else { return false }
        if before.st_gid != group, changeOwner(fd, owner, group) != 0 { return false }
        var after = stat()
        return fstat(fd, &after) == 0 && after.st_uid == owner && after.st_gid == group
            && after.st_mode & S_IFMT == S_IFREG && after.st_mode & 0o7777 == 0o600
            && after.st_nlink == 1 && after.st_dev == before.st_dev && after.st_ino == before.st_ino
            && after.st_size == before.st_size
    }
}

/// CPU key labels are the SMC protocol mappings published by Stats and VirtualSMC.
/// The transport and control implementation are independent; no upstream implementation is embedded.
public final class ThermalReader: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: SMCConnection?
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    public init() {
        let brand = Self.cpuBrand()
        let keys = Self.sensorKeys(cpuBrand: brand)
        cpuKeys = keys.cpu; gpuKeys = keys.gpu
    }

    public func sample() -> ThermalSnapshot {
        lock.lock(); defer { lock.unlock() }
        do {
            if connection == nil { connection = try SMCConnection() }
            guard let connection else { throw ThermalError.unavailable("AppleSMC") }
            var sensors: [TemperatureSensor] = []
            for (keys, group) in [(cpuKeys, "CPU"), (gpuKeys, "GPU")] {
                for key in keys {
                    if let value = try? connection.number(key), value.isFinite, value > 0, value < 130 {
                        sensors.append(TemperatureSensor(key: key, name: "\(group) · \(key)", group: group, celsius: value))
                    }
                }
            }
            for (key, name) in [("TB1T", "电池"), ("TB2T", "电池 2"), ("TH0x", "储存"), ("TaLP", "左侧气流"), ("TaRF", "右侧气流")] {
                if let value = try? connection.number(key), value.isFinite, value > 0, value < 130 {
                    sensors.append(TemperatureSensor(key: key, name: name, group: "系统", celsius: value))
                }
            }
            let cpu = sensors.filter { $0.group == "CPU" }.map(\.celsius)
            var warnings: [String] = []
            if cpu.isEmpty { warnings.append("此设备没有可确认映射的 CPU 温度读数。") }
            let fans: [FanReading]
            do { fans = try connection.fans() }
            catch { fans = []; warnings.append(error.localizedDescription) }
            return ThermalSnapshot(cpuTemperatureCelsius: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                                   temperatureSensors: sensors, fans: fans, warnings: warnings)
        } catch {
            connection = nil
            return ThermalSnapshot(cpuTemperatureCelsius: nil, temperatureSensors: [], fans: [], warnings: [error.localizedDescription])
        }
    }

    static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    static func sensorKeys(cpuBrand: String) -> (cpu: [String], gpu: [String]) {
        if cpuBrand.contains("Apple M5") {
            return (["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
                    ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])
        }
        if cpuBrand.contains("Apple M4") {
            return (["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                    ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        }
        if cpuBrand.contains("Apple M3") {
            return (["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                    ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        }
        if cpuBrand.contains("Apple M2") {
            return (["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], ["Tg0f", "Tg0j"])
        }
        if cpuBrand.contains("Apple M1") {
            return (["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        }
        if cpuBrand.contains("Intel") {
            return (["TC0D", "TCAD", "TC0E", "TC0F"], ["TG0D", "TGDD"])
        }
        return ([], [])
    }
}

public struct FanCoolingDecision: Equatable, Sendable {
    public let mode: FanCoolingMode
    public let targetFraction: Double
    public let shouldRestore: Bool
    public let reason: String?
    public init(mode: FanCoolingMode, targetFraction: Double, shouldRestore: Bool = false, reason: String? = nil) {
        self.mode = mode; self.targetFraction = targetFraction; self.shouldRestore = shouldRestore; self.reason = reason
    }
}

/// Called by the independently running helper. No fan write is scheduled by a reader or initializer.
public struct FanCoolingPolicy: Sendable {
    public let mode: FanCoolingMode
    public let startedAt: TimeInterval
    public let maximumDuration: TimeInterval
    private var missingSince: TimeInterval?
    private var cooledSince: TimeInterval?
    public init(mode: FanCoolingMode, now: TimeInterval, maximumDuration: TimeInterval = 1800) {
        self.mode = mode; startedAt = now; self.maximumDuration = min(1800, max(1, maximumDuration))
    }
    public mutating func update(snapshot: ThermalSnapshot, cpuUsage: Double, now: TimeInterval) -> FanCoolingDecision {
        func restore(_ reason: String) -> FanCoolingDecision {
            FanCoolingDecision(mode: .automatic, targetFraction: 0, shouldRestore: true, reason: reason)
        }
        if mode == .automatic { return restore("已交回系统自动调节。") }
        guard now >= startedAt, now - startedAt < maximumDuration else { return restore("定时降温已结束。") }
        guard let temperature = snapshot.cpuTemperatureCelsius, temperature.isFinite, (1..<130).contains(temperature),
              abs(snapshot.sampledAt.timeIntervalSinceNow) <= 10 else {
            if missingSince == nil { missingSince = now }
            if now - (missingSince ?? now) >= 10 { return restore("无法读取温度，已交回系统自动调节。") }
            return FanCoolingDecision(mode: mode, targetFraction: 1)
        }
        missingSince = nil
        if mode == .maxCool { return FanCoolingDecision(mode: mode, targetFraction: 1) }
        if temperature <= 60, cpuUsage.isFinite, cpuUsage <= 25 {
            if cooledSince == nil { cooledSince = now }
            if now - (cooledSince ?? now) >= 60 { return restore("温度和负载已回落，已交回系统自动调节。") }
        } else { cooledSince = nil }
        // At least 60% of the hardware range; full speed from 85°C. Never requests a fan stop.
        return FanCoolingDecision(mode: mode, targetFraction: min(1, max(0.6, 0.6 + (temperature - 60) / 25 * 0.4)))
    }
}

/// Root helper's only SMC mutation interface. It never accepts a key or arbitrary bytes from a client.
/// A caller must keep its own watchdog alive and call restoreAutomatic on disconnect, sleep and exit.
public final class ThermalFanHardware: @unchecked Sendable {
    private let lock = NSLock()
    private let readSnapshot: @Sendable () -> ThermalSnapshot
    private let isAuthorized: @Sendable () -> Bool
    private var connection: (any SMCFanDevice)?
    private var ownsControl = false
    private var floorRPM: [Int: Double] = [:]
    public init() {
        let reader = ThermalReader()
        readSnapshot = { reader.sample() }
        isAuthorized = { geteuid() == 0 }
    }
    init(device: any SMCFanDevice, readSnapshot: @escaping @Sendable () -> ThermalSnapshot,
         isAuthorized: @escaping @Sendable () -> Bool) {
        connection = device; self.readSnapshot = readSnapshot; self.isAuthorized = isAuthorized
    }
    /// True only after this instance passed the foreign-controller check and may have written.
    /// It remains true after an unconfirmed partial rollback, so a watchdog can retry.
    public var requiresAutomaticRestore: Bool {
        lock.lock(); defer { lock.unlock() }; return ownsControl
    }

    public func apply(mode: FanCoolingMode, targetFraction: Double) throws -> ThermalSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard isAuthorized() else { throw ThermalError.authorizationRequired }
        if mode == .automatic {
            // This fixed command represents an explicit request to hand control to the system.
            ownsControl = true
            return try restoreLocked()
        }
        guard targetFraction.isFinite, (0.6...1).contains(targetFraction) else { throw ThermalError.invalidCommand }
        let connection = try device()
        let initial = try connection.fans()
        guard !initial.isEmpty else { throw ThermalError.unavailable("没有可控制的风扇。") }
        guard initial.allSatisfy({ $0.mode != .unknown }) else { throw ThermalError.readbackFailed("风扇模式不可读。") }
        for fan in initial {
            guard fan.minimumRPM >= 0, fan.maximumRPM > fan.minimumRPM,
                  fan.maximumRPM <= 30000 else { throw ThermalError.invalidFanLimits(fan.id) }
        }
        if !ownsControl, initial.contains(where: { $0.mode == .manual }) { throw ThermalError.manualControlInUse }
        if !ownsControl {
            floorRPM = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, max($0.actualRPM, $0.targetRPM)) })
            ownsControl = true
        }
        do {
            for fan in initial {
                let fraction = mode == .maxCool ? 1 : targetFraction
                let rpm = min(fan.maximumRPM, max(floorRPM[fan.id] ?? 0,
                              fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * fraction))
                try setManual(connection, fan: fan)
                try connection.writeFanTarget(id: fan.id, rpm: rpm)
                try verifyTarget(connection, fan: fan, rpm: rpm)
            }
            return readSnapshot()
        } catch {
            do { _ = try restoreLocked() }
            catch let restoreError {
                throw ThermalError.readbackFailed("风扇指令失败，且自动恢复尚未确认：\(restoreError.localizedDescription)")
            }
            throw error
        }
    }

    @discardableResult public func restoreAutomatic() throws -> ThermalSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard isAuthorized() else { throw ThermalError.authorizationRequired }
        guard ownsControl else {
            // A refused acquisition, invalid command or preflight failure must never reset
            // another controller through cleanup, a sleep callback, or a retry loop.
            let snapshot = readSnapshot()
            if snapshot.automaticModeVerified == true { return snapshot }
            if snapshot.fans.contains(where: { $0.mode == .manual }) { throw ThermalError.manualControlInUse }
            throw ThermalError.readbackFailed("未取得风扇控制，当前自动模式无法核对；未写入硬件。")
        }
        return try restoreLocked()
    }

    private func device() throws -> any SMCFanDevice {
        if connection == nil { connection = try SMCConnection() }
        return connection!
    }

    private func setManual(_ connection: any SMCFanDevice, fan: FanReading) throws {
        if fan.mode == .manual { return }
        do { try connection.writeFanMode(id: fan.id, modeKey: fan.modeKey, manual: true) }
        catch {
            // Older Apple Silicon requires the fixed Ftst test-mode handshake. M5 uses F0md directly.
            #if arch(arm64)
            guard (try? connection.number("Ftst")) != nil else { throw error }
            try connection.writeTestMode(true)
            var accepted = false
            for _ in 0..<20 {
                usleep(50_000)
                if (try? connection.writeFanMode(id: fan.id, modeKey: fan.modeKey, manual: true)) != nil {
                    accepted = true; break
                }
            }
            guard accepted else { throw ThermalError.hardwareRejected("风扇手动模式未生效。") }
            #else
            throw error
            #endif
        }
    }

    private func verifyTarget(_ connection: any SMCFanDevice, fan: FanReading, rpm: Double) throws {
        var observed: FanReading?
        for attempt in 0..<20 {
            observed = try connection.fans().first { $0.id == fan.id }
            if let observed, observed.mode == .manual, abs(observed.targetRPM - rpm) <= max(5, rpm * 0.01) { return }
            // Allow the target value to propagate while manual ownership remains visible.
            // Never reassert mode or reissue a target if the system/another controller took over.
            guard observed?.mode == .manual else { break }
            if attempt < 19 { usleep(25_000) }
        }
        let expected = String(format: "%.1f", rpm)
        let target = observed.map { String(format: "%.1f", $0.targetRPM) } ?? "不可读"
        let mode = observed?.mode.rawValue ?? "不可读"
        throw ThermalError.readbackFailed("风扇 \(fan.id + 1)：期望目标 \(expected) RPM，实测目标 \(target) RPM，模式 \(mode)（\(observed?.modeKey ?? fan.modeKey)）。")
    }

    private func restoreLocked() throws -> ThermalSnapshot {
        let connection = try device()
        // A failed RPM, target or limit sensor must never prevent the independent mode reset.
        let fans = try connection.fanModes()
        guard !fans.isEmpty else { throw ThermalError.unavailable("无法核对自动模式。") }
        var failures: [String] = []
        // Restore all controlled fans even if the first one fails.
        for fan in fans {
            do { try connection.writeFanMode(id: fan.id, modeKey: fan.modeKey, manual: false) }
            catch { failures.append(error.localizedDescription) }
        }
        #if arch(arm64)
        if (try? connection.number("Ftst")) == 1 {
            do { try connection.writeTestMode(false) } catch { failures.append(error.localizedDescription) }
        }
        #endif
        let observed = try connection.fanModes()
        guard Set(observed.map(\.id)) == Set(fans.map(\.id)), observed.allSatisfy({ $0.mode == .automatic || $0.mode == .system }) else {
            throw ThermalError.readbackFailed("不能确认所有风扇已经交回系统。\(failures.joined(separator: "；"))")
        }
        ownsControl = false; floorRPM = [:]
        let snapshot = readSnapshot()
        guard snapshot.fans.allSatisfy({ $0.mode == .automatic || $0.mode == .system }) else {
            throw ThermalError.readbackFailed("模式读回后有其他程序重新接管风扇。")
        }
        return snapshot.confirmingAutomaticMode()
    }
}

// The 80-byte AppleSMC user-client protocol is not a Swift ABI struct. Explicit offsets avoid
// compiler padding. This layout was checked against live read-only Apple M5 Pro responses.
struct SMCValue: Equatable {
    let key: String
    let type: String
    let bytes: [UInt8]
    var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            return Double(Float(bitPattern: SMCWire.read32(bytes, 0)))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ": return bytes.count == 1 ? Double(bytes[0]) : nil
        case "ui16", "ui32":
            guard bytes.count == (type == "ui16" ? 2 : 4) else { return nil }
            return Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: return nil
        }
    }
}

enum SMCWire {
    static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func string(_ code: UInt32) -> String {
        String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? ""
    }
    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    static func set32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * index)) & 255) }
    }
    static func request(key: String, operation: UInt8, size: Int = 0, data: [UInt8] = []) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 80)
        set32(&bytes, 0, code(key)); set32(&bytes, 28, UInt32(size)); bytes[42] = operation
        for (index, byte) in data.prefix(32).enumerated() { bytes[48 + index] = byte }
        return bytes
    }
    static func numberBytes(_ value: Double, type: String, size: Int) throws -> [UInt8] {
        guard value.isFinite, value >= 0, value <= 30000 else { throw ThermalError.invalidCommand }
        switch (type, size) {
        case ("flt ", 4):
            var bytes = [UInt8](repeating: 0, count: 4)
            set32(&bytes, 0, Float(value).bitPattern); return bytes
        case ("fpe2", 2):
            guard value <= 16383 else { throw ThermalError.invalidCommand }
            let raw = UInt16((value * 4).rounded()); return [UInt8(raw >> 8), UInt8(raw & 255)]
        case ("ui8 ", 1):
            guard value <= 255, value.rounded() == value else { throw ThermalError.invalidCommand }
            return [UInt8(value)]
        case ("ui16", 2):
            guard value.rounded() == value else { throw ThermalError.invalidCommand }
            let raw = UInt16(value); return [UInt8(raw >> 8), UInt8(raw & 255)]
        default: throw ThermalError.hardwareRejected("\(type)/\(size) 写入格式不支持。")
        }
    }
}

struct SMCFanMode {
    let id: Int
    let modeKey: String
    let mode: FanHardwareMode
}

protocol SMCFanDevice: AnyObject {
    func number(_ key: String) throws -> Double
    func fans() throws -> [FanReading]
    func fanModes() throws -> [SMCFanMode]
    func writeFanTarget(id: Int, rpm: Double) throws
    func writeFanMode(id: Int, modeKey: String, manual: Bool) throws
    func writeTestMode(_ enabled: Bool) throws
}

extension SMCFanDevice {
    func fanModes() throws -> [SMCFanMode] {
        try fans().map { SMCFanMode(id: $0.id, modeKey: $0.modeKey, mode: $0.mode) }
    }
}

private final class SMCConnection: SMCFanDevice {
    private var connection: io_connect_t = 0
    private var infoCache: [String: (size: Int, type: String)] = [:]
    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw ThermalError.unavailable("AppleSMC 服务不存在。") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw ThermalError.unavailable("IOServiceOpen \(result)") }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        let output = try call(SMCWire.request(key: key, operation: 5, size: info.size))
        return SMCValue(key: key, type: info.type, bytes: Array(output[48..<(48 + info.size)]))
    }
    func number(_ key: String) throws -> Double {
        guard let number = try read(key).number, number.isFinite else { throw ThermalError.unavailable("\(key) 数据格式不支持。") }
        return number
    }
    func fans() throws -> [FanReading] {
        try fanModes().map { fan in
            let id = fan.id
            let actual = try number("F\(id)Ac"), minimum = try number("F\(id)Mn"), maximum = try number("F\(id)Mx")
            let target = try number("F\(id)Tg")
            guard actual >= 0, minimum >= 0, maximum > minimum, maximum <= 30000,
                  actual <= maximum * 1.2, target >= 0, target <= maximum * 1.2 else { throw ThermalError.invalidFanLimits(id) }
            return FanReading(id: id, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum,
                              targetRPM: target, mode: fan.mode, modeKey: fan.modeKey)
        }
    }
    func fanModes() throws -> [SMCFanMode] {
        let countValue = try number("FNum")
        guard countValue.rounded() == countValue, (0...8).contains(countValue) else { throw ThermalError.unavailable("风扇数量无效。") }
        return (0..<Int(countValue)).map { id in
            let modeKey = (try? keyInfo("F\(id)md")) != nil ? "F\(id)md" : "F\(id)Md"
            let rawMode = try? number(modeKey)
            let mode: FanHardwareMode
            #if arch(arm64)
            switch rawMode { case 0: mode = .automatic; case 1: mode = .manual; case 3: mode = .system; default: mode = .unknown }
            #else
            if let mask = try? number("FS! ") { mode = (Int(mask) & (1 << id)) != 0 ? .manual : .automatic }
            else { mode = .unknown }
            #endif
            return SMCFanMode(id: id, modeKey: modeKey, mode: mode)
        }
    }
    func writeFanTarget(id: Int, rpm: Double) throws {
        guard (0..<8).contains(id), rpm.isFinite, let fan = try fans().first(where: { $0.id == id }),
              rpm >= fan.minimumRPM, rpm <= fan.maximumRPM else { throw ThermalError.invalidCommand }
        guard fan.mode == .manual else {
            throw ThermalError.readbackFailed("F\(id)Tg 写入前模式已变为 \(fan.mode.rawValue)（\(fan.modeKey)），未重新接管。")
        }
        try writeNumber("F\(id)Tg", value: rpm)
    }
    func writeFanMode(id: Int, modeKey: String, manual: Bool) throws {
        guard (0..<8).contains(id), ["F\(id)Md", "F\(id)md"].contains(modeKey) else { throw ThermalError.invalidCommand }
        #if arch(arm64)
        try writeNumber(modeKey, value: manual ? 1 : 0)
        let observed = try number(modeKey)
        guard manual ? observed == 1 : (observed == 0 || observed == 3) else {
            throw ThermalError.readbackFailed("\(modeKey)：期望模式 \(manual ? "1" : "0/3")，实测 \(observed)。")
        }
        #else
        let mask = Int(try number("FS! "))
        let newMask = manual ? mask | (1 << id) : mask & ~(1 << id)
        try writeNumber("FS! ", value: Double(newMask))
        guard Int(try number("FS! ")) == newMask else { throw ThermalError.readbackFailed("FS! ") }
        #endif
    }
    func writeTestMode(_ enabled: Bool) throws { try writeNumber("Ftst", value: enabled ? 1 : 0) }

    private func keyInfo(_ key: String) throws -> (size: Int, type: String) {
        guard key.utf8.count == 4 else { throw ThermalError.invalidCommand }
        if let info = infoCache[key] { return info }
        let output = try call(SMCWire.request(key: key, operation: 9))
        let size = Int(SMCWire.read32(output, 28))
        guard (1...32).contains(size) else { throw ThermalError.unavailable("\(key) 不存在。") }
        let info = (size, SMCWire.string(SMCWire.read32(output, 32)))
        infoCache[key] = info
        return info
    }
    private func writeNumber(_ key: String, value: Double) throws {
        guard geteuid() == 0 else { throw ThermalError.authorizationRequired }
        let allowed = key == "Ftst" || key == "FS! " || (0..<8).contains { key == "F\($0)Tg" || key == "F\($0)md" || key == "F\($0)Md" }
        guard allowed, value.isFinite, value >= 0, value <= 30000 else { throw ThermalError.invalidCommand }
        let info = try keyInfo(key)
        let data = try SMCWire.numberBytes(value, type: info.type, size: info.size)
        _ = try call(SMCWire.request(key: key, operation: 6, size: info.size, data: data))
    }
    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 80), size = 80
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, input.count, destination.baseAddress, &size)
            }
        }
        guard result == KERN_SUCCESS, size == 80, output[40] == 0 else {
            throw ThermalError.hardwareRejected("IOKit \(result)，SMC \(output[40])")
        }
        return output
    }
}
