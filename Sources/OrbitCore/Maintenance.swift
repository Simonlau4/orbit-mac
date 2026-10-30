import Foundation
import Darwin

public enum MaintenanceTask: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case dnsCache, quickLookCache, systemDNS
    case auditBrokenCommandLinks, auditLegacyOverrides, auditLoginItems, cleanBrokenLaunchAgents
    case cleanQuarantineEvents, cleanSavedState, ejectStaleDiskImages, memoryPurge, pruneNotificationDB
    case pruneSpotlightOrphanRules, rebuildQuickLook, repairBrokenPlists, repairDiskPermissions
    case repairSharedFileLists, runPeriodicMaintenance, vacuumSQLiteDatabases
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dnsCache: return "刷新 DNS 查询缓存"
        case .quickLookCache: return "刷新文件缩略图"
        case .systemDNS: return "重新加载系统 DNS"
        case .auditBrokenCommandLinks: return "检查已删除 App 留下的命令"
        case .auditLegacyOverrides: return "恢复 App 休眠与磁盘镜像校验默认值"
        case .auditLoginItems: return "检查失效登录项"
        case .cleanBrokenLaunchAgents: return "整理失效后台服务"
        case .cleanQuarantineEvents: return "清空下载隔离记录"
        case .cleanSavedState: return "清理 30 天前的窗口状态"
        case .ejectStaleDiskImages: return "弹出闲置磁盘镜像"
        case .memoryPurge: return "释放闲置物理内存"
        case .pruneNotificationDB: return "清理 30 天前的通知记录"
        case .pruneSpotlightOrphanRules: return "清理已卸载 App 遗留的 Spotlight 规则"
        case .rebuildQuickLook: return "重建快速预览缓存"
        case .repairBrokenPlists: return "修复损坏配置文件"
        case .repairDiskPermissions: return "修复个人目录读写权限"
        case .repairSharedFileLists: return "整理损坏的最近使用与边栏列表"
        case .runPeriodicMaintenance: return "执行系统例行维护"
        case .vacuumSQLiteDatabases: return "压缩邮件和信息数据"
        }
    }
    public var detail: String {
        switch self {
        case .dnsCache: return "刷新系统域名查询缓存。"
        case .quickLookCache: return "清除 Quick Look 缩略图缓存，预览会按需重建。"
        case .systemDNS: return "刷新查询缓存并重新加载系统解析服务。"
        case .auditBrokenCommandLinks: return "查找指向已移除应用的命令链接，逐项审阅后保留恢复副本。"
        case .auditLegacyOverrides: return "只移除明确开启的全局 App Nap 与磁盘镜像跳过校验设置，保留旧值。"
        case .auditLoginItems: return "检查系统登录项并显示失效目标；更改由 macOS 系统设置管理。"
        case .cleanBrokenLaunchAgents: return "仅检查个人代理；已加载、受保护或外置磁盘未连接的服务会保留。"
        case .cleanQuarantineEvents: return "清理下载历史数据库，保留恢复副本；文件上的安全隔离标记保持有效。"
        case .cleanSavedState: return "仅移走 30 天未更新且对应应用未运行的窗口状态。"
        case .ejectStaleDiskImages: return "列出已挂载的只读磁盘镜像，确认后正常弹出；正在使用时系统会拒绝。"
        case .memoryPurge: return "有内存压力时调用系统 purge；文件缓存会重新建立，短时增加磁盘读取。"
        case .pruneNotificationDB: return "核对数据库结构并备份，只移除 30 天前的已送达通知。"
        case .pruneSpotlightOrphanRules: return "仅清理确认没有安装对应应用的第三方搜索规则，保留系统规则和恢复副本。"
        case .rebuildQuickLook: return "重新加载 Quick Look 生成器，不删除文档。"
        case .repairBrokenPlists: return "隔离无法解析的第三方偏好设置，让应用重新生成；可在维护记录中恢复。"
        case .repairDiskPermissions: return "按当前账号重置个人目录所有权与 ACL；只在出现权限故障时执行，不能自动撤销。"
        case .repairSharedFileLists: return "隔离损坏列表，保留应用最近文档和有效列表；可恢复。"
        case .runPeriodicMaintenance: return "系统提供 periodic 时执行 daily、weekly、monthly；不可用时明确报告。"
        case .vacuumSQLiteDatabases: return "先核对完整性并备份，再压缩 Mail、Messages 与 Safari 的空闲页；不删会话。"
        }
    }
    public var requiresAdmin: Bool { [.systemDNS, .memoryPurge, .repairDiskPermissions, .runPeriodicMaintenance, .auditLoginItems].contains(self) }
    public var usesCommand: Bool { [.dnsCache, .quickLookCache, .systemDNS, .rebuildQuickLook, .memoryPurge, .repairDiskPermissions, .runPeriodicMaintenance].contains(self) }
}

public enum MaintenanceStatus: String, Codable, Sendable {
    case success, failed, cancelled, timedOut, skipped, unavailable
}

public struct MaintenanceResult: Codable, Sendable {
    public let task: MaintenanceTask
    public let status: MaintenanceStatus
    public let message: String
    public let output: String
    public let elapsedSeconds: TimeInterval
}

public struct MaintenanceCommand: Equatable, Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let timeoutSeconds: TimeInterval

    public init(executable: String, arguments: [String], timeoutSeconds: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct MaintenanceCommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
    public let cancelled: Bool

    public init(exitCode: Int32, output: String, timedOut: Bool = false, cancelled: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

public typealias MaintenanceRunner = @Sendable (MaintenanceCommand) async -> MaintenanceCommandResult

public actor MaintenanceService {
    private let runner: MaintenanceRunner

    public init(runner: MaintenanceRunner? = nil) {
        self.runner = runner ?? { command in await Self.execute(command) }
    }

    public static func command(for task: MaintenanceTask) -> MaintenanceCommand {
        switch task {
        case .dnsCache:
            return MaintenanceCommand(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"], timeoutSeconds: 10)
        case .quickLookCache:
            return MaintenanceCommand(executable: "/usr/bin/qlmanage", arguments: ["-r", "cache"], timeoutSeconds: 15)
        case .rebuildQuickLook:
            return MaintenanceCommand(executable: "/usr/bin/qlmanage", arguments: ["-r"], timeoutSeconds: 15)
        case .auditLoginItems:
            return MaintenanceCommand(executable: "/usr/bin/osascript", arguments: ["-e", "do shell script \"/usr/bin/sfltool dumpbtm\" with administrator privileges"], timeoutSeconds: 120)
        case .memoryPurge:
            return MaintenanceCommand(executable: "/usr/bin/osascript", arguments: ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"], timeoutSeconds: 120)
        case .repairDiskPermissions:
            // The UID comes from the current process, never from a UI path or parameter.
            return MaintenanceCommand(executable: "/usr/bin/osascript", arguments: ["-e", "do shell script \"/usr/sbin/diskutil resetUserPermissions / \(getuid())\" with administrator privileges"], timeoutSeconds: 300)
        case .runPeriodicMaintenance:
            return MaintenanceCommand(executable: "/usr/bin/osascript", arguments: ["-e", "do shell script \"/usr/sbin/periodic daily weekly monthly\" with administrator privileges"], timeoutSeconds: 300)
        case .systemDNS:
            // The script is fixed; no path, label or text from the UI is interpolated.
            return MaintenanceCommand(executable: "/usr/bin/osascript", arguments: ["-e", "do shell script \"/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder\" with administrator privileges"], timeoutSeconds: 120)
        default:
            // File/database operations must be previewed by MaintenanceEngine, never routed to a shell.
            return MaintenanceCommand(executable: "/usr/bin/false", arguments: [], timeoutSeconds: 1)
        }
    }

    /// Call only after the UI confirms this specific task. Nothing runs at initialization.
    public func run(_ task: MaintenanceTask) async -> MaintenanceResult {
        let started = ProcessInfo.processInfo.systemUptime
        guard task.usesCommand else {
            return MaintenanceResult(task: task, status: .failed, message: "请先检查并审阅具体项目。", output: "", elapsedSeconds: 0)
        }
        if task == .runPeriodicMaintenance && !FileManager.default.isExecutableFile(atPath: "/usr/sbin/periodic") {
            return MaintenanceResult(task: task, status: .unavailable, message: "当前 macOS 不再提供 periodic，此项未执行。", output: "", elapsedSeconds: 0)
        }
        if Task.isCancelled {
            return MaintenanceResult(task: task, status: .cancelled, message: "操作已取消。", output: "", elapsedSeconds: 0)
        }
        let result = await runner(Self.command(for: task))
        let output = String(result.output.prefix(16_384))
        let status: MaintenanceStatus
        let message: String
        if result.cancelled || (task.requiresAdmin && (output.contains("(-128)") || output.localizedCaseInsensitiveContains("user canceled"))) {
            status = .cancelled; message = "操作已取消。"
        } else if result.timedOut {
            status = .timedOut; message = "操作超时，已停止 Orbit 启动的命令。"
        } else if result.exitCode != 0 {
            status = .failed; message = output.isEmpty ? "系统命令执行失败（\(result.exitCode)）。" : output
        } else {
            status = .success
            switch task {
            case .dnsCache: message = "DNS 查询缓存已刷新。"
            case .quickLookCache: message = "文件预览缓存重建请求已完成。"
            case .systemDNS: message = "系统 DNS 已重新加载。"
            default: message = task.title + "已完成。"
            }
        }
        return MaintenanceResult(task: task, status: status, message: message, output: output,
                                 elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
    }

    /// Exposed for isolated executable fixtures; app actions use only command(for:).
    public static func execute(_ command: MaintenanceCommand) async -> MaintenanceCommandResult {
        let control = MaintenanceProcessControl()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    if control.isCancelled {
                        continuation.resume(returning: MaintenanceCommandResult(exitCode: -1, output: "", cancelled: true))
                        return
                    }
                    let process = Process()
                    let pipe = Pipe()
                    let ended = DispatchSemaphore(value: 0)
                    let output = MaintenanceOutput()
                    let readEnded = DispatchGroup()
                    process.executableURL = URL(fileURLWithPath: command.executable)
                    process.arguments = command.arguments
                    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = pipe
                    process.standardError = pipe
                    process.terminationHandler = { _ in ended.signal() }
                    do { try process.run() } catch {
                        continuation.resume(returning: MaintenanceCommandResult(exitCode: -1, output: error.localizedDescription))
                        return
                    }
                    control.attach(process)
                    readEnded.enter()
                    DispatchQueue.global(qos: .utility).async {
                        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty { output.append(chunk) }
                        readEnded.leave()
                    }
                    let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, command.timeoutSeconds)
                    var finished = false
                    while !finished {
                        finished = ended.wait(timeout: .now() + 0.05) == .success
                        if control.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { break }
                    }
                    if !finished {
                        if process.isRunning { process.terminate() }
                        if ended.wait(timeout: .now() + 0.3) != .success, process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                            _ = ended.wait(timeout: .now() + 0.3)
                        }
                    }
                    _ = readEnded.wait(timeout: .now() + 0.5)
                    control.detach()
                    continuation.resume(returning: MaintenanceCommandResult(
                        exitCode: process.isRunning ? -1 : process.terminationStatus,
                        output: output.text, timedOut: !finished && !control.isCancelled,
                        cancelled: control.isCancelled))
                }
            }
        }, onCancel: { control.cancel() })
    }
}

private final class MaintenanceProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ process: Process) {
        lock.lock(); self.process = process; let stop = cancelled; lock.unlock()
        if stop, process.isRunning { process.terminate() }
    }
    func detach() { lock.lock(); process = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let target = process; lock.unlock()
        if let target, target.isRunning { target.terminate() }
    }
}

private final class MaintenanceOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < 16_384 { data.append(chunk.prefix(16_384 - data.count)) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
