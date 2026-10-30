import Foundation
import IOKit
import IOKit.pwr_mgt

/// Serializes fan writes with power events. Sleep is acknowledged after recovery/readback;
/// the same session cannot write again after a sleep or wake event.
public final class ThermalSleepGuard: @unchecked Sendable {
    // IOMessage.h function-like macros are unavailable to Swift.
    static let canSystemSleep: UInt32 = 0xe0000270
    static let systemWillSleep: UInt32 = 0xe0000280
    static let systemHasPoweredOn: UInt32 = 0xe0000300
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.orbitmac.Orbit.FanAgent.power")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let applyOperation: @Sendable (FanCoolingMode, Double) throws -> ThermalSnapshot
    private let restoreOperation: @Sendable () throws -> ThermalSnapshot
    private var requestedStop = false
    private var attemptedControl = false
    private var sleepRestoreError: String?
    private var sleepRestoreSuccess: Bool?
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let context = SleepCallbackContext()

    public convenience init(hardware: ThermalFanHardware) throws {
        self.init(apply: { try hardware.apply(mode: $0, targetFraction: $1) }, restore: { try hardware.restoreAutomatic() })
        try observePower()
    }
    init(apply: @escaping @Sendable (FanCoolingMode, Double) throws -> ThermalSnapshot,
         restore: @escaping @Sendable () throws -> ThermalSnapshot) {
        applyOperation = apply; restoreOperation = restore
        context.owner = self
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit { close() }
    public var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return requestedStop }
    public var lastSleepRestoreError: String? { lock.lock(); defer { lock.unlock() }; return sleepRestoreError }
    public var didRestoreForSleep: Bool? { lock.lock(); defer { lock.unlock() }; return sleepRestoreSuccess }

    public func apply(mode: FanCoolingMode, targetFraction: Double) throws -> ThermalSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard !requestedStop else { throw ThermalError.hardwareRejected("睡眠或退出已终止当前降温会话。") }
        attemptedControl = true // A partially failed apply also needs recovery.
        return try applyOperation(mode, targetFraction)
    }
    @discardableResult public func restoreAutomatic() throws -> ThermalSnapshot {
        lock.lock(); defer { lock.unlock() }
        requestedStop = true
        return try restoreOperation()
    }
    public func close() {
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != true { queue.sync {} }
        if rootPort != 0 { IOServiceClose(rootPort); rootPort = 0 }
    }
    private func observePower() throws {
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(context).toOpaque(), &notificationPort, Self.callback, &notifier)
        guard rootPort != 0, let notificationPort else {
            close(); throw ThermalError.unavailable("无法注册系统睡眠恢复，风扇控制未启动。")
        }
        IONotificationPortSetDispatchQueue(notificationPort, queue)
    }
    private static let callback: IOServiceInterestCallback = { reference, _, message, argument in
        guard let reference else { return }
        let context = Unmanaged<SleepCallbackContext>.fromOpaque(reference).takeUnretainedValue()
        context.owner?.powerMessage(message, notificationID: Int(bitPattern: argument))
    }
    func powerMessage(_ message: UInt32, notificationID: Int) {
        switch message {
        case Self.canSystemSleep:
            if rootPort != 0 { IOAllowPowerChange(rootPort, notificationID) }
        case Self.systemWillSleep:
            prepareForSleep()
            if rootPort != 0 { IOAllowPowerChange(rootPort, notificationID) }
        case Self.systemHasPoweredOn: prepareForSleep()
        default: break
        }
    }
    func prepareForSleep() {
        lock.lock(); defer { lock.unlock() }
        requestedStop = true
        guard attemptedControl else { return }
        for _ in 0..<3 {
            do {
                let snapshot = try restoreOperation()
                guard snapshot.automaticModeVerified == true || (!snapshot.fans.isEmpty && snapshot.fans.allSatisfy({ $0.mode == .automatic || $0.mode == .system })) else {
                    throw ThermalError.readbackFailed("睡眠前不能确认风扇自动模式。")
                }
                sleepRestoreSuccess = true; sleepRestoreError = nil
                return
            } catch { sleepRestoreError = error.localizedDescription; sleepRestoreSuccess = false }
        }
    }
}

private final class SleepCallbackContext: @unchecked Sendable { weak var owner: ThermalSleepGuard? }
