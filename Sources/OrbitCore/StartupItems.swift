import Foundation
import Darwin

public enum StartupScope: String, Codable, Sendable {
    case userAgent, systemAgent, systemDaemon
    public var title: String {
        switch self { case .userAgent: return "个人启动代理"; case .systemAgent: return "系统启动代理"; case .systemDaemon: return "系统后台服务" }
    }
}

public struct StartupItem: Identifiable, Sendable {
    public let url: URL
    public let label: String
    public let program: String
    public let arguments: [String]
    public let scope: StartupScope
    /// Whether the configuration is in LaunchAgents; this does not mean the process is running.
    public let isEnabled: Bool
    public let canToggle: Bool
    public let originalURL: URL?
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let triggerSummary: String
    public var id: String { (originalURL ?? url).path }
    fileprivate let identity: StartupIdentity
}

public struct StartupScan: Sendable {
    public let items: [StartupItem]
    public let warnings: [String]
}

public struct LaunchctlResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String = "") { self.status = status; self.output = output }
}

public typealias LaunchctlRunner = @Sendable ([String]) async throws -> LaunchctlResult

public actor StartupItemsService {
    private let home: URL
    private let runner: LaunchctlRunner
    private let systemRoots: [(URL, StartupScope)]
    private let fm = FileManager.default
    private var userRoot: URL { home.appendingPathComponent("Library/LaunchAgents") }
    private var storage: URL { home.appendingPathComponent("Library/Application Support/Orbit/DisabledLaunchAgents") }
    private var journalURL: URL { storage.appendingPathComponent("index.json") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, runner: LaunchctlRunner? = nil, includeSystem: Bool = true) {
        self.home = home
        self.runner = runner ?? { arguments in try StartupCommand.run(arguments) }
        self.systemRoots = includeSystem ? [(URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent), (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon), (URL(fileURLWithPath: "/System/Library/LaunchAgents"), .systemAgent), (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), .systemDaemon)] : []
    }

    public func scan() -> StartupScan {
        var items: [StartupItem] = []
        var warnings: [String] = []
        for (root, scope) in [(userRoot, StartupScope.userAgent)] + systemRoots where fm.fileExists(atPath: root.path) {
            do {
                try ApplicationPaths.noLinks(root)
                let urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                for url in urls where url.pathExtension == "plist" {
                    do { items.append(try descriptor(url, scope: scope, enabled: true)) }
                    catch { if warnings.count < 20 { warnings.append("未能读取启动配置：\(url.path)") } }
                }
            } catch { warnings.append("无法读取启动项目录：\(root.path)") }
        }
        do {
            for record in try load() {
                if fm.fileExists(atPath: record.storedURL.path) {
                    let current = try StartupIdentity(record.storedURL)
                    guard record.pending ? current.sameFile(as: record.identity) : current == record.identity else { throw StartupError.changed }
                    items.append(try descriptor(record.storedURL, scope: .userAgent, enabled: false, original: record.originalURL))
                } else if !fm.fileExists(atPath: record.originalURL.path) {
                    warnings.append("停用记录缺少配置文件：\(record.originalURL.lastPathComponent)")
                } else if record.pending {
                    warnings.append("上次停用未完成，配置仍在原位置：\(record.originalURL.lastPathComponent)")
                } else {
                    warnings.append("上次启用可能中断，配置已在原位置；可重新停用：\(record.originalURL.lastPathComponent)")
                }
            }
        } catch { warnings.append("停用记录不可读或配置已变化；已停止提供该部分恢复操作。") }
        return StartupScan(items: items.sorted { ($0.scope.rawValue, $0.label) < ($1.scope.rawValue, $1.label) }, warnings: warnings)
    }

    public func setEnabled(_ enabled: Bool, item: StartupItem) async throws {
        guard item.canToggle, item.scope == .userAgent, item.isEnabled != enabled else {
            if item.isEnabled == enabled { return }
            throw StartupError.readOnly
        }
        let original = item.originalURL ?? item.url
        try validateOriginal(original)
        try ensureDirectory(storage)
        let lock = open(storage.appendingPathComponent("mutation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw StartupError.busy }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw StartupError.busy }
        defer { flock(lock, LOCK_UN) }
        try ApplicationPaths.noLinks(item.url)
        guard try StartupIdentity(item.url) == item.identity else { throw StartupError.changed }
        guard Self.validLabel(item.label), !item.label.hasPrefix("com.apple."), item.label.lowercased() != "com.orbitmac.orbit" else { throw StartupError.invalidLabel }
        var records = try load()
        // A crash after moving an enabled configuration back, before journal commit,
        // must not leave a stale record that prevents the next explicit mutation.
        records.removeAll { record in
            !fm.fileExists(atPath: record.storedURL.path)
                && (try? StartupIdentity(record.originalURL).sameFile(as: record.identity)) == true
        }
        if enabled {
            guard let index = records.firstIndex(where: { $0.originalURL.path == original.path && $0.storedURL.path == item.url.path }) else { throw StartupError.missingRecord }
            guard !fm.fileExists(atPath: original.path) else { throw StartupError.conflict }
            try ensureDirectory(userRoot)
            try fm.moveItem(at: item.url, to: original)
            let restoredIdentity = try StartupIdentity(original)
            let result: LaunchctlResult
            do { result = try await runner(["bootstrap", "gui/\(getuid())", original.path]) }
            catch {
                try rollbackEnable(original: original, stored: item.url, expected: restoredIdentity, records: &records, index: index)
                throw error
            }
            guard result.status == 0 else {
                try rollbackEnable(original: original, stored: item.url, expected: restoredIdentity, records: &records, index: index)
                throw StartupError.command(result.output)
            }
            records.remove(at: index)
            try save(records)
        } else {
            try ensureDirectory(storage)
            records.removeAll { $0.originalURL.path == original.path && $0.pending && !fm.fileExists(atPath: $0.storedURL.path) }
            guard !records.contains(where: { $0.originalURL.path == original.path }) else { throw StartupError.conflict }
            let record = DisabledStartup(id: UUID(), originalURL: original, storedURL: storage.appendingPathComponent(UUID().uuidString + ".plist"), identity: item.identity, pending: true)
            records.append(record)
            try save(records) // An interrupted move retains its destination and original identity.
            do {
                let result = try await runner(["bootout", "gui/\(getuid())/\(item.label)"])
                let notLoaded = [3, 113].contains(result.status) && (result.output.localizedCaseInsensitiveContains("no such process") || result.output.localizedCaseInsensitiveContains("could not find service"))
                guard result.status == 0 || notLoaded else { throw StartupError.command(result.output) }
                try ApplicationPaths.noLinks(original)
                guard try StartupIdentity(original) == item.identity else { throw StartupError.changed }
                try fm.moveItem(at: original, to: record.storedURL)
            } catch {
                if fm.fileExists(atPath: original.path) { records.removeAll { $0.id == record.id }; try save(records) }
                throw error
            }
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index].identity = try StartupIdentity(record.storedURL)
                records[index].pending = false
            }
            try save(records)
        }
    }

    private func rollbackEnable(original: URL, stored: URL, expected: StartupIdentity, records: inout [DisabledStartup], index: Int) throws {
        try ApplicationPaths.noLinks(original)
        try ApplicationPaths.noLinks(stored.deletingLastPathComponent())
        guard try StartupIdentity(original) == expected else { throw StartupError.changed }
        guard !fm.fileExists(atPath: stored.path) else { throw StartupError.conflict }
        try fm.moveItem(at: original, to: stored)
        records[index].identity = try StartupIdentity(stored)
        try save(records)
    }

    private func descriptor(_ url: URL, scope: StartupScope, enabled: Bool, original: URL? = nil) throws -> StartupItem {
        try ApplicationPaths.noLinks(url)
        let identity = try StartupIdentity(url)
        guard identity.regular else { throw StartupError.readOnly }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576, let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any], let label = plist["Label"] as? String, Self.validLabel(label) else { throw StartupError.invalidLabel }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? arguments.first ?? "未声明程序"
        let exactUserLocation = (original ?? url).deletingLastPathComponent().path == userRoot.path
        let runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        let conditionalKeepAlive = (plist["KeepAlive"] as? [String: Any])?.isEmpty == false
        let keepAlive = plist["KeepAlive"] as? Bool == true || conditionalKeepAlive
        let triggerSummary = conditionalKeepAlive ? "条件保持运行" : keepAlive ? "持续保持运行" : runAtLoad ? "登录时运行" : "按配置条件启动"
        return StartupItem(url: url, label: label, program: program, arguments: arguments, scope: scope, isEnabled: enabled,
                           canToggle: scope == .userAgent && exactUserLocation && identity.owner == getuid() && !label.hasPrefix("com.apple.") && label.lowercased() != "com.orbitmac.orbit", originalURL: original,
                           runAtLoad: runAtLoad, keepAlive: keepAlive, triggerSummary: triggerSummary, identity: identity)
    }

    private func validateOriginal(_ url: URL) throws {
        guard url.deletingLastPathComponent().path == userRoot.path, url.pathExtension == "plist" else { throw StartupError.readOnly }
    }

    private static func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 256 && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    private struct DisabledStartup: Codable {
        let id: UUID
        let originalURL: URL
        let storedURL: URL
        var identity: StartupIdentity
        var pending: Bool
    }

    private func load() throws -> [DisabledStartup] {
        guard fm.fileExists(atPath: journalURL.path) else { return [] }
        try ApplicationPaths.noLinks(journalURL)
        let data = try Data(contentsOf: journalURL)
        guard data.count <= 2_097_152 else { throw StartupError.missingRecord }
        let records = try JSONDecoder().decode([DisabledStartup].self, from: data)
        for record in records {
            try validateOriginal(record.originalURL)
            guard record.storedURL.deletingLastPathComponent().path == storage.path else { throw StartupError.missingRecord }
        }
        return records
    }

    private func save(_ records: [DisabledStartup]) throws {
        try ensureDirectory(storage)
        if fm.fileExists(atPath: journalURL.path) { try ApplicationPaths.noLinks(journalURL) }
        try JSONEncoder().encode(records).write(to: journalURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func ensureDirectory(_ url: URL) throws {
        var ancestor = url
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        try ApplicationPaths.noLinks(ancestor)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ApplicationPaths.noLinks(url)
    }
}

private struct StartupIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: Int64
    let modifiedNanos: Int64
    let changed: Int64
    let changedNanos: Int64
    let owner: UInt32
    let regular: Bool
    init(_ url: URL) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT != S_IFLNK else { throw StartupError.changed }
        device = s.st_dev; inode = s.st_ino; size = s.st_size; owner = s.st_uid
        modified = Int64(s.st_mtimespec.tv_sec); modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
        changed = Int64(s.st_ctimespec.tv_sec); changedNanos = Int64(s.st_ctimespec.tv_nsec)
        regular = s.st_mode & S_IFMT == S_IFREG
    }
    func sameFile(as other: StartupIdentity) -> Bool {
        device == other.device && inode == other.inode && size == other.size && modified == other.modified && modifiedNanos == other.modifiedNanos && owner == other.owner && regular == other.regular
    }
}

public enum StartupError: LocalizedError {
    case readOnly, changed, invalidLabel, missingRecord, conflict, busy, command(String)
    public var errorDescription: String? {
        switch self {
        case .readOnly: return "仅支持切换当前用户自有的 LaunchAgents；其他启动项请在系统设置中管理。"
        case .changed: return "启动配置已经变化或不再是普通文件，请重新读取。"
        case .invalidLabel: return "启动配置没有有效的 Label。"
        case .missingRecord: return "停用记录缺失或无效，已停止操作。"
        case .conflict: return "原位置或停用记录已有配置，无法覆盖。"
        case .busy: return "另一项启动配置变更正在进行，请稍后重试。"
        case .command(let message): return "系统未完成启动项变更：\(message.prefix(500))"
        }
    }
}

private enum StartupCommand {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var value = Data()
        func store(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func read() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func run(_ arguments: [String]) throws -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { output.store(pipe.fileHandleForReading.readDataToEndOfFile()); done.signal() }
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        _ = done.wait(timeout: .now() + 1)
        return LaunchctlResult(status: process.terminationStatus, output: String(decoding: output.read().prefix(4096), as: UTF8.self))
    }
}
