import Foundation
import CryptoKit
import AppKit
import Darwin

public enum MaintenanceChange: String, Codable, Sendable { case quarantine, brokenLink, pruneQuarantine, pruneNotifications, vacuum, preference, eject }

public struct MaintenanceCandidate: Identifiable, Codable, Sendable {
    public var id: String { url.path + "#" + (key ?? change.rawValue) }
    public let url: URL
    public let name: String
    public let detail: String
    public let bytes: Int64
    public let change: MaintenanceChange
    public let fingerprint: String
    public let bundleID: String?
    public let key: String?
    public let replacement: Data?
}

public struct MaintenancePlan: Identifiable, Sendable {
    public let id = UUID()
    public let task: MaintenanceTask
    public let candidates: [MaintenanceCandidate]
    public let warnings: [String]
    public let summary: String
    public let canRunCommand: Bool
    public let findings: [String]
}

public struct MaintenanceRecoveryEntry: Codable, Sendable {
    public let candidate: MaintenanceCandidate
    public let backup: URL
    public var afterFingerprint: String?
    public var completed: Bool
    public var restored: Bool
    public var backupFingerprint: String? = nil
    public var expectedPreference: Data? = nil
    public var restoring: Bool? = nil
    public var restorationFingerprint: String? = nil
    public var restoredPreference: Data? = nil
}

public struct MaintenanceRecoveryRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let task: MaintenanceTask
    public let createdAt: Date
    public var entries: [MaintenanceRecoveryEntry]
    public var message: String
    public var isRestored: Bool { !entries.isEmpty && entries.allSatisfy(\.restored) }
}

private enum MaintenanceFailure: LocalizedError {
    case denied(String), changed, busy, missing, limit
    var errorDescription: String? {
        switch self {
        case .denied(let text): return text
        case .changed: return "项目在预览后发生变化，已保留。请重新检查。"
        case .busy: return "已有维护正在运行，或文件仍被其他程序使用。"
        case .missing: return "恢复副本不可用。"
        case .limit: return "此项目超过检查预算，已保留。"
        }
    }
}

/// Each plan is read-only. Mutations require explicit IDs from the review screen.
/// Recovery copies remain local and are never automatically purged.
public actor MaintenanceEngine {
    private let home: URL
    private let storage: URL
    private let fm = FileManager.default
    private let fixtureMode: Bool
    private let checksOpenFiles: Bool
    private var inFlight = false
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, storage: URL? = nil, checkOpenFiles: Bool? = nil) {
        self.home = home
        self.storage = storage ?? home.appendingPathComponent("Library/Application Support/Orbit/MaintenanceRecovery")
        fixtureMode = home.path != FileManager.default.homeDirectoryForCurrentUser.path
        checksOpenFiles = checkOpenFiles ?? (home.path == FileManager.default.homeDirectoryForCurrentUser.path)
    }
    private var journal: URL { storage.appendingPathComponent("history.json") }
    private var legacyNotificationURL: URL? {
        guard !fixtureMode else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard confstr(_CS_DARWIN_USER_DIR, &bytes, bytes.count) > 0 else { return nil }
        guard let physical = realpath(String(cString: bytes), nil) else { return nil }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("com.apple.notificationcenter/db2/db")
    }

    public func preview(_ task: MaintenanceTask, installedBundleIDs: Set<String>? = nil,
                        runningBundleIDs: Set<String>? = nil, now: Date = Date()) async -> MaintenancePlan {
        var found: [MaintenanceCandidate] = []
        var warnings: [String] = []
        var findings: [String] = []
        let running = runningBundleIDs ?? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let started = ProcessInfo.processInfo.systemUptime
        func children(_ relative: String) -> [URL] {
            let directory = home.appendingPathComponent(relative)
            guard fm.fileExists(atPath: directory.path) else { return [] }
            do {
                try Self.noLinks(directory)
                return Array(try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).prefix(2000))
            } catch { warnings.append("无法读取：" + directory.path); return [] }
        }
        func append(_ url: URL, change: MaintenanceChange, detail: String, bundleID: String? = nil,
                    key: String? = nil, replacement: Data? = nil) {
            guard !Task.isCancelled, found.count < 200, ProcessInfo.processInfo.systemUptime - started < 20 else {
                if warnings.last != "已达到检查预算，结果为部分覆盖。" { warnings.append("已达到检查预算，结果为部分覆盖。") }; return
            }
            if let bundleID, running.contains(bundleID) { warnings.append("正在使用，保留：" + url.lastPathComponent); return }
            do {
                try allowed(url, task: task, change: change)
                let stamp = try Self.fingerprint(url, allowLink: change == .brokenLink)
                let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                found.append(MaintenanceCandidate(url: url, name: url.lastPathComponent, detail: detail, bytes: bytes,
                    change: change, fingerprint: stamp, bundleID: bundleID, key: key, replacement: replacement))
            } catch { warnings.append("已保留 \(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        switch task {
        case .cleanSavedState:
            for url in children("Library/Saved Application State") where url.pathExtension == "savedState" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(date) >= 30 * 86400, (try? Self.newestModification(url)) ?? now < now.addingTimeInterval(-30 * 86400) {
                    append(url, change: .quarantine, detail: "30 天前的窗口状态", bundleID: url.deletingPathExtension().lastPathComponent)
                }
            }
        case .repairBrokenPlists:
            for url in children("Library/Preferences") where url.pathExtension == "plist" && Self.thirdParty(url.deletingPathExtension().lastPathComponent) {
                if !Self.validPlist(url) {
                    append(url, change: .quarantine, detail: "无法解析的第三方偏好设置", bundleID: url.deletingPathExtension().lastPathComponent)
                }
            }
        case .repairSharedFileLists:
            let root = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
            if fm.fileExists(atPath: root.path) {
                do {
                    try Self.noLinks(root)
                    let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, _ in false })
                    var visits = 0
                    while let url = iterator?.nextObject() as? URL {
                        visits += 1
                        if visits > 2000 || Task.isCancelled || ProcessInfo.processInfo.systemUptime - started > 20 { warnings.append("列表检查仅覆盖部分项目。"); break }
                        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator?.skipDescendants(); continue }
                        if ["sfl2", "sfl3", "sfl4"].contains(url.pathExtension), !url.path.contains("ApplicationRecentDocuments"), !Self.validPlist(url) {
                            append(url, change: .quarantine, detail: "无法解析的列表；有效列表和应用最近文档保留")
                        }
                    }
                } catch { warnings.append(error.localizedDescription) }
            }
        case .cleanBrokenLaunchAgents:
            for url in children("Library/LaunchAgents") where url.pathExtension == "plist" {
                guard let plist = try? Self.readPlist(url), let label = plist["Label"] as? String, Self.thirdParty(label),
                      let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first,
                      program.hasPrefix("/"), !program.hasPrefix("/Volumes/"), !fm.fileExists(atPath: program),
                      !Self.protectedService(label) else { continue }
                if !fixtureMode {
                    let loaded = await Self.command("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
                    guard loaded.exitCode != 0, loaded.output.contains("Could not find service") else { warnings.append("服务已加载或状态未确认，保留：" + label); continue }
                }
                append(url, change: .quarantine, detail: "目标程序已不存在且服务未加载；保存原配置")
            }
        case .auditBrokenCommandLinks:
            for directory in [".local/bin", "bin"] {
                for url in children(directory) {
                    guard let destination = try? fm.destinationOfSymbolicLink(atPath: url.path), destination.hasPrefix("/Applications/") || destination.hasPrefix(home.appendingPathComponent("Applications").path + "/"),
                          destination.contains(".app/"), !fm.fileExists(atPath: destination) else { continue }
                    append(url, change: .brokenLink, detail: "链接指向已移除的 App：" + destination)
                }
            }
        case .auditLegacyOverrides:
            for (relative, keys) in [(".GlobalPreferences.plist", ["NSAppSleepDisabled"]), ("com.apple.frameworks.diskimages.plist", ["skip-verify", "skip-verify-locked", "skip-verify-remote"])] {
                let url = home.appendingPathComponent("Library/Preferences/" + relative)
                guard let values = try? Self.readPlist(url) else { continue }
                let active = keys.filter { (values[$0] as? NSNumber)?.boolValue == true }
                if !active.isEmpty {
                    append(url, change: .preference, detail: "移除旧覆盖值：" + active.joined(separator: "、"), key: active.joined(separator: "|"))
                }
            }
        case .pruneSpotlightOrphanRules:
            let url = home.appendingPathComponent("Library/Preferences/com.apple.spotlight.plist")
            if let plist = try? Self.readPlist(url), let rules = plist["EnabledPreferenceRules"] as? [String] {
                let inventory: Set<String>
                if let ids = installedBundleIDs { inventory = ids }
                else {
                    let scan = await ApplicationInventory().scan()
                    if !scan.warnings.isEmpty { warnings.append("应用清单读取不完整，搜索规则全部保留。"); break }
                    inventory = Set(scan.apps.map(\.bundleID))
                }
                let removed = rules.filter { Self.thirdParty($0) && !inventory.contains($0) && (fixtureMode || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil) }
                if !removed.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: rules.filter { !removed.contains($0) }, format: .binary, options: 0) {
                    append(url, change: .preference, detail: "移除 \(removed.count) 条第三方规则：" + removed.joined(separator: "、"), key: "EnabledPreferenceRules", replacement: data)
                }
            }
        case .cleanQuarantineEvents:
            let url = home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
            if fm.fileExists(atPath: url.path) {
                let count = await Self.scalar(url, "SELECT COUNT(*) FROM LSQuarantineEvent;")
                if let count, count > 0 { append(url, change: .pruneQuarantine, detail: "移除 \(count) 条下载历史；文件安全标记保留") }
                else if count == nil { warnings.append("无法读取下载历史数据库，或结构不受支持。") }
            }
        case .pruneNotificationDB:
            let modern = home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
            var url = modern
            if !fm.fileExists(atPath: modern.path), let legacy = legacyNotificationURL { url = legacy }
            if fm.fileExists(atPath: url.path) {
                // delivered_date uses Cocoa's 2001 reference epoch on macOS, not Unix 1970.
                let invalidDates = await Self.scalar(url, "SELECT COUNT(*) FROM record WHERE delivered_date IS NOT NULL AND typeof(delivered_date) NOT IN ('integer','real');")
                guard invalidDates == 0 else { warnings.append("通知时间字段不是受支持的数值格式，数据库保留。"); break }
                let cutoff = Int64(now.timeIntervalSinceReferenceDate - 30 * 86400)
                let maximum = await Self.scalar(url, "SELECT CAST(MAX(delivered_date) AS INTEGER) FROM record;")
                if let maximum, maximum > Int64(now.timeIntervalSinceReferenceDate + 86400) { warnings.append("通知时间格式不受支持，数据库保留。"); break }
                let count = await Self.scalar(url, "SELECT COUNT(*) FROM record WHERE delivered_date > 0 AND delivered_date < \(cutoff);")
                if let count, count > 0 { append(url, change: .pruneNotifications, detail: "移除 \(count) 条 30 天前的已送达通知", key: String(cutoff)) }
                else if count == nil { warnings.append("通知数据库不可读或结构不受支持；需要完全磁盘访问权限时请在系统设置授予。") }
            } else { warnings.append("未找到当前系统支持的通知数据库。") }
        case .vacuumSQLiteDatabases:
            var urls = ["Library/Messages/chat.db", "Library/Safari/History.db", "Library/Safari/TopSites.db"].map { home.appendingPathComponent($0) }
            for version in children("Library/Mail") where version.lastPathComponent.range(of: "^V[0-9]+$", options: .regularExpression) != nil {
                urls.append(version.appendingPathComponent("MailData/Envelope Index"))
            }
            for url in urls where fm.fileExists(atPath: url.path) {
                let id = url.path.contains("/Mail/") ? "com.apple.mail" : url.path.contains("/Messages/") ? "com.apple.MobileSMS" : "com.apple.Safari"
                if let pages = await Self.scalar(url, "PRAGMA freelist_count;"), pages > 0 {
                    append(url, change: .vacuum, detail: "回收 \(pages) 个空闲页，不删除记录", bundleID: id)
                } else if await Self.scalar(url, "PRAGMA page_count;") == nil { warnings.append("无法读取：" + url.path) }
            }
        case .ejectStaleDiskImages:
            let info = await Self.command("/usr/bin/hdiutil", ["info", "-plist"])
            if info.exitCode == 0, let data = info.output.data(using: .utf8), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let images = plist["images"] as? [[String: Any]] {
                for image in images where image["writeable"] as? Bool == false {
                    for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                        if let point = entity["mount-point"] as? String, point.hasPrefix("/Volumes/"), let device = entity["dev-entry"] as? String, device.range(of: "^/dev/disk[0-9]+s?[0-9]*$", options: .regularExpression) != nil {
                            let url = URL(fileURLWithPath: point)
                            found.append(MaintenanceCandidate(url: url, name: url.lastPathComponent, detail: "正常弹出只读镜像 " + device, bytes: 0, change: .eject, fingerprint: device, bundleID: nil, key: nil, replacement: nil))
                        }
                    }
                }
            } else { warnings.append("无法读取已挂载镜像。") }
        case .auditLoginItems:
            let result = await Self.command("/usr/bin/sfltool", ["dumpbtm"], timeout: 15)
            if result.exitCode == 0 {
                findings = Self.loginFindings(result.output, home: home)
                if result.output.utf8.count >= 16_384 { warnings.append("系统登录项输出达到上限，本次只覆盖已读取部分。") }
                warnings.append("系统登录项由 macOS 设置管理；个人代理可在软件 → 启动项停用和恢复。")
            }
            else { warnings.append("无法读取系统登录项。" + result.output.prefix(250)) }
        default: break
        }
        if Task.isCancelled { warnings.append("检查已取消，结果可能不完整。") }
        var canCommand = task.usesCommand
        if task == .runPeriodicMaintenance && !fm.isExecutableFile(atPath: "/usr/sbin/periodic") {
            canCommand = false; warnings.append("当前 macOS 不再提供 periodic，此项不可用。")
        }
        if task == .memoryPurge {
            let pressure = await Self.command("/usr/bin/memory_pressure", [])
            if let line = pressure.output.components(separatedBy: "\n").first(where: { $0.contains("System-wide memory free percentage:") }),
               let value = Int(line.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.last ?? ""), value > 20 {
                canCommand = false; warnings.append("当前内存压力正常，无需强制回收文件缓存。")
            }
        }
        let summary = canCommand ? task.detail : found.isEmpty ? "本次检查未发现可执行变更。" : "共 \(found.count) 项，执行前会再次核对；恢复副本会保留在本机。"
        return MaintenancePlan(task: task, candidates: found, warnings: Array(warnings.prefix(30)), summary: summary, canRunCommand: canCommand, findings: findings)
    }

    public func execute(_ plan: MaintenancePlan, selectedIDs: Set<String>, runningBundleIDs: Set<String>? = nil) async -> MaintenanceResult {
        let start = ProcessInfo.processInfo.systemUptime
        guard !inFlight else { return result(plan.task, .failed, MaintenanceFailure.busy.localizedDescription, start) }
        inFlight = true; defer { inFlight = false }
        if plan.canRunCommand { return await MaintenanceService().run(plan.task) }
        let selected = plan.candidates.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return result(plan.task, .skipped, "没有选择任何变更。", start) }
        var records: [MaintenanceRecoveryRecord] = []
        var record = MaintenanceRecoveryRecord(id: UUID(), task: plan.task, createdAt: Date(), entries: [], message: "准备维护")
        var applied = 0
        var heldLock: Int32?
        defer { if let fd = heldLock { flock(fd, LOCK_UN); close(fd) } }
        do {
            try ensureStorage()
            heldLock = try acquireLock()
            records = try load()
            let directory = storage.appendingPathComponent(record.id.uuidString)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            records.append(record)
            try save(records)
            for (index, candidate) in selected.enumerated() {
                try Task.checkCancellation()
                try allowed(candidate.url, task: plan.task, change: candidate.change)
                let running = runningBundleIDs ?? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                if let id = candidate.bundleID, running.contains(id) { throw MaintenanceFailure.busy }
                if candidate.change == .eject {
                    let fresh = await preview(.ejectStaleDiskImages)
                    guard fresh.candidates.contains(where: { $0.url == candidate.url && $0.fingerprint == candidate.fingerprint }) else { throw MaintenanceFailure.changed }
                    let detached = await Self.command("/usr/bin/hdiutil", ["detach", candidate.fingerprint], timeout: 30)
                    guard detached.exitCode == 0 else { throw MaintenanceFailure.denied(detached.output) }
                    applied += 1; continue
                }
                let expected = record.entries.last(where: { $0.candidate.url == candidate.url && $0.completed })?.afterFingerprint ?? candidate.fingerprint
                guard try Self.fingerprint(candidate.url, allowLink: candidate.change == .brokenLink) == expected else { throw MaintenanceFailure.changed }
                if candidate.change == .pruneQuarantine || candidate.change == .pruneNotifications || candidate.change == .vacuum {
                    try await requireClosed(candidate.url)
                    let integrity = await Self.sqlite(candidate.url, "PRAGMA quick_check;", readonly: true)
                    guard integrity.exitCode == 0, integrity.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw MaintenanceFailure.denied("数据库完整性未通过，已保留。") }
                }
                if plan.task == .cleanBrokenLaunchAgents, !fixtureMode {
                    guard let plist = try? Self.readPlist(candidate.url), let label = plist["Label"] as? String else { throw MaintenanceFailure.changed }
                    let current = await Self.command("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
                    guard current.exitCode != 0, current.output.contains("Could not find service") else { throw MaintenanceFailure.busy }
                }
                let backup = directory.appendingPathComponent(String(index) + ".backup")
                record.entries.append(MaintenanceRecoveryEntry(candidate: candidate, backup: backup, afterFingerprint: nil, completed: false, restored: false))
                records[records.count - 1] = record; try save(records) // Intent is durable before any move or DB mutation.
                switch candidate.change {
                case .quarantine, .brokenLink:
                    guard try Self.fingerprint(candidate.url, allowLink: candidate.change == .brokenLink) == candidate.fingerprint else { throw MaintenanceFailure.changed }
                    try fm.moveItem(at: candidate.url, to: backup)
                case .preference:
                    try fm.copyItem(at: candidate.url, to: backup)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    record.entries[record.entries.count - 1].backupFingerprint = try Self.fingerprint(backup)
                    record.entries[record.entries.count - 1].expectedPreference = try preferenceResult(candidate, restoring: false, backup: backup)
                    records[records.count - 1] = record; try save(records)
                    try changePreference(candidate, restoring: false, backup: backup)
                case .pruneQuarantine, .pruneNotifications, .vacuum:
                    let copy = await Self.sqlite(candidate.url, ".backup '" + backup.path.replacingOccurrences(of: "'", with: "''") + "'", readonly: true)
                    guard copy.exitCode == 0 else { throw MaintenanceFailure.denied("数据库备份失败：" + copy.output) }
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    record.entries[record.entries.count - 1].backupFingerprint = try Self.fingerprint(backup)
                    records[records.count - 1] = record; try save(records)
                    let staged = candidate.url.deletingLastPathComponent().appendingPathComponent(".OrbitMaintenance-" + UUID().uuidString + ".sqlite")
                    try fm.copyItem(at: backup, to: staged)
                    defer { try? fm.removeItem(at: staged) }
                    let sql: String
                    switch candidate.change {
                    case .pruneQuarantine: sql = "BEGIN IMMEDIATE; DELETE FROM LSQuarantineEvent; COMMIT; VACUUM; PRAGMA quick_check;"
                    case .pruneNotifications:
                        guard let key = candidate.key, let cutoff = Int64(key), cutoff > 0, cutoff < Int64(Date().timeIntervalSinceReferenceDate) else { throw MaintenanceFailure.changed }
                        sql = "BEGIN IMMEDIATE; DELETE FROM record WHERE delivered_date > 0 AND delivered_date < \(cutoff); COMMIT; VACUUM; PRAGMA quick_check;"
                    default: sql = "VACUUM; PRAGMA quick_check;"
                    }
                    let changed = await Self.sqlite(staged, sql, readonly: false, timeout: 60)
                    guard changed.exitCode == 0, changed.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw MaintenanceFailure.denied("数据库维护未完成，恢复副本已保留：" + changed.output) }
                    try await requireClosed(candidate.url)
                    guard try Self.fingerprint(candidate.url) == candidate.fingerprint else { throw MaintenanceFailure.changed }
                    // Journal the exact replacement before its atomic rename, so crash recovery
                    // can distinguish our output from a later application write.
                    record.entries[record.entries.count - 1].afterFingerprint = try Self.fingerprint(staged)
                    records[records.count - 1] = record; try save(records)
                    guard rename(staged.path, candidate.url.path) == 0 else { throw MaintenanceFailure.denied("数据库替换未完成，原文件和备份均保留。") }
                case .eject: break
                }
                let entryIndex = record.entries.count - 1
                if fm.fileExists(atPath: candidate.url.path) { record.entries[entryIndex].afterFingerprint = try Self.fingerprint(candidate.url) }
                record.entries[entryIndex].completed = true
                applied += 1; record.message = "已完成 \(applied) 项"
                records[records.count - 1] = record; try save(records)
            }
            return result(plan.task, .success, "已完成 \(applied) 项。文件与数据库变更可在维护恢复记录中还原。", start)
        } catch {
            if !record.entries.isEmpty, !records.isEmpty { record.message = error.localizedDescription; records[records.count - 1] = record; try? save(records) }
            return result(plan.task, error is CancellationError ? .cancelled : .failed, "已完成 \(applied) 项。" + error.localizedDescription + (record.entries.isEmpty ? "" : "\n已保留恢复记录。"), start)
        }
    }

    /// Read-only OS database access; call only from the explicit administrator-authentication button.
    public func authorizedLoginAudit(runner: MaintenanceRunner? = nil) async -> MaintenancePlan {
        let command = MaintenanceService.command(for: .auditLoginItems)
        let result = await (runner ?? { await MaintenanceService.execute($0) })(command)
        let succeeded = result.exitCode == 0 && !result.timedOut && !result.cancelled
        let warnings = succeeded ? ["系统登录项请到 macOS 设置停用或移除，个人启动代理在软件页管理。"]
            : [result.output.contains("(-128)") ? "系统认证已取消，未读取登录项。" : "系统登录项读取未完成：" + String(result.output.prefix(280))]
        return MaintenancePlan(task: .auditLoginItems, candidates: [], warnings: warnings,
            summary: succeeded ? "只读审计完成，未更改任何登录项。" : "需要系统授权才能读取完整登录项。", canRunCommand: false,
            findings: succeeded ? Self.loginFindings(result.output, home: home) : [])
    }

    public func history() throws -> [MaintenanceRecoveryRecord] {
        try load().reversed()
    }

    public func restore(_ id: UUID) async throws {
        guard !inFlight else { throw MaintenanceFailure.busy }
        inFlight = true; defer { inFlight = false }
        try ensureStorage()
        let fd = try acquireLock(); defer { flock(fd, LOCK_UN); close(fd) }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw MaintenanceFailure.missing }
        for entryIndex in records[index].entries.indices.reversed() {
            var entry = records[index].entries[entryIndex]
            if entry.restored { continue }
            let candidate = entry.candidate
            if let bundleID = candidate.bundleID, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID && !$0.isTerminated }) { throw MaintenanceFailure.busy }
            try allowed(candidate.url, task: records[index].task, change: candidate.change, missingAllowed: true)
            try Self.noLinks(entry.backup.deletingLastPathComponent())
            guard entry.backup.deletingLastPathComponent().path == storage.appendingPathComponent(id.uuidString).path else { throw MaintenanceFailure.missing }
            var originalStat = stat()
            if entry.restoring == true, lstat(candidate.url.path, &originalStat) == 0 {
                let matches = candidate.change == .preference
                    ? Self.plistMatches(candidate.url, data: entry.restoredPreference)
                    : (try Self.fingerprint(candidate.url, allowLink: candidate.change == .brokenLink)) == (entry.restorationFingerprint ?? candidate.fingerprint)
                if matches {
                    entry.restored = true; records[index].entries[entryIndex] = entry; try save(records); continue
                }
            }
            guard fm.fileExists(atPath: entry.backup.path) || (try? fm.destinationOfSymbolicLink(atPath: entry.backup.path)) != nil else { throw MaintenanceFailure.missing }
            if let backupHash = entry.backupFingerprint {
                guard try Self.fingerprint(entry.backup, allowLink: candidate.change == .brokenLink) == backupHash else { throw MaintenanceFailure.changed }
            }
            switch candidate.change {
            case .quarantine, .brokenLink:
                var st = stat()
                guard lstat(candidate.url.path, &st) != 0, errno == ENOENT else { throw MaintenanceFailure.changed }
                guard try Self.fingerprint(entry.backup, allowLink: candidate.change == .brokenLink) == candidate.fingerprint else { throw MaintenanceFailure.changed }
                try Self.noLinks(candidate.url.deletingLastPathComponent())
                entry.restoring = true; entry.restorationFingerprint = candidate.fingerprint
                records[index].entries[entryIndex] = entry; try save(records)
                try fm.moveItem(at: entry.backup, to: candidate.url)
            case .preference, .pruneQuarantine, .pruneNotifications, .vacuum:
                let current = try Self.fingerprint(candidate.url)
                if current == candidate.fingerprint {
                    entry.restored = true; records[index].entries[entryIndex] = entry; try save(records); continue
                }
                guard current == entry.afterFingerprint || (candidate.change == .preference && Self.plistMatches(candidate.url, data: entry.expectedPreference)) else { throw MaintenanceFailure.changed }
                if candidate.change == .preference {
                    entry.restoring = true; entry.restoredPreference = try preferenceResult(candidate, restoring: true, backup: entry.backup)
                    records[index].entries[entryIndex] = entry; try save(records)
                    try changePreference(candidate, restoring: true, backup: entry.backup)
                }
                else {
                    try await requireClosed(candidate.url)
                    let check = await Self.sqlite(entry.backup, "PRAGMA quick_check;", readonly: true)
                    guard check.exitCode == 0, check.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw MaintenanceFailure.missing }
                    let staged = candidate.url.deletingLastPathComponent().appendingPathComponent(".OrbitRestore-" + UUID().uuidString + ".sqlite")
                    try fm.copyItem(at: entry.backup, to: staged)
                    defer { try? fm.removeItem(at: staged) }
                    entry.restoring = true; entry.restorationFingerprint = try Self.fingerprint(staged)
                    records[index].entries[entryIndex] = entry; try save(records)
                    try await requireClosed(candidate.url)
                    guard try Self.fingerprint(candidate.url) == current else { throw MaintenanceFailure.changed }
                    guard rename(staged.path, candidate.url.path) == 0 else { throw MaintenanceFailure.denied("恢复替换未完成，现有文件与副本均保留。") }
                }
            case .eject: continue
            }
            entry.restored = true; records[index].entries[entryIndex] = entry
            try save(records)
        }
    }

    private func preferenceResult(_ candidate: MaintenanceCandidate, restoring: Bool, backup: URL) throws -> Data {
        guard let key = candidate.key else { throw MaintenanceFailure.changed }
        var plist = try Self.readPlist(candidate.url)
        for part in key.split(separator: "|").map(String.init) {
            if restoring { plist[part] = try Self.readPlist(backup)[part] }
            else if let data = candidate.replacement { plist[part] = try PropertyListSerialization.propertyList(from: data, format: nil) }
            else { plist[part] = nil }
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }
    private static func plistMatches(_ url: URL, data: Data?) -> Bool {
        guard let data, let expected = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let current = try? readPlist(url) else { return false }
        return NSDictionary(dictionary: current).isEqual(to: expected)
    }
    private func changePreference(_ candidate: MaintenanceCandidate, restoring: Bool, backup: URL) throws {
        guard let key = candidate.key else { throw MaintenanceFailure.changed }
        let result = try preferenceResult(candidate, restoring: restoring, backup: backup)
        let plist = try PropertyListSerialization.propertyList(from: result, format: nil) as! [String: Any]
        if fixtureMode {
            try result.write(to: candidate.url, options: .atomic)
        } else {
            let name = candidate.url.deletingPathExtension().lastPathComponent
            let domain = name == ".GlobalPreferences" ? kCFPreferencesAnyApplication : name as CFString
            for part in key.split(separator: "|").map(String.init) {
                CFPreferencesSetValue(part as CFString, plist[part] as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw MaintenanceFailure.denied("偏好设置未能保存。") }
            guard Self.plistMatches(candidate.url, data: result) else { throw MaintenanceFailure.changed }
        }
    }

    private func allowed(_ url: URL, task: MaintenanceTask, change: MaintenanceChange, missingAllowed: Bool = false) throws {
        let legacy = task == .pruneNotificationDB && url.path == legacyNotificationURL?.path
        guard !url.pathComponents.contains(".."), url.path.hasPrefix(home.path + "/") || legacy || (change == .eject && url.path.hasPrefix("/Volumes/")) else { throw MaintenanceFailure.denied("此路径不在维护范围内。") }
        if change == .eject { return }
        let relative = String(url.path.dropFirst(home.path.count + 1))
        let approved: Bool
        switch task {
        case .cleanSavedState: approved = relative.hasPrefix("Library/Saved Application State/") && url.pathExtension == "savedState"
        case .repairBrokenPlists: approved = url.deletingLastPathComponent().path == home.appendingPathComponent("Library/Preferences").path && Self.thirdParty(url.deletingPathExtension().lastPathComponent) && url.pathExtension == "plist"
        case .cleanBrokenLaunchAgents: approved = url.deletingLastPathComponent().path == home.appendingPathComponent("Library/LaunchAgents").path && url.pathExtension == "plist" && Self.thirdParty(url.deletingPathExtension().lastPathComponent) && !Self.protectedService(url.lastPathComponent)
        case .repairSharedFileLists: approved = relative.hasPrefix("Library/Application Support/com.apple.sharedfilelist/") && !relative.contains("ApplicationRecentDocuments") && ["sfl2", "sfl3", "sfl4"].contains(url.pathExtension)
        case .auditBrokenCommandLinks: approved = [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent("bin").path].contains(url.deletingLastPathComponent().path) && change == .brokenLink
        case .auditLegacyOverrides: approved = ["Library/Preferences/.GlobalPreferences.plist", "Library/Preferences/com.apple.frameworks.diskimages.plist"].contains(relative) && change == .preference
        case .pruneSpotlightOrphanRules: approved = relative == "Library/Preferences/com.apple.spotlight.plist" && change == .preference
        case .cleanQuarantineEvents: approved = relative == "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2" && change == .pruneQuarantine
        case .pruneNotificationDB: approved = (relative == "Library/Group Containers/group.com.apple.usernoted/db2/db" || legacy) && change == .pruneNotifications
        case .vacuumSQLiteDatabases:
            approved = (["Library/Messages/chat.db", "Library/Safari/History.db", "Library/Safari/TopSites.db"].contains(relative) || relative.range(of: "^Library/Mail/V[0-9]+/MailData/Envelope Index$", options: .regularExpression) != nil) && change == .vacuum
        default: approved = false
        }
        guard approved else { throw MaintenanceFailure.denied("此项目未通过维护范围校验。") }
        try Self.noLinks(change == .brokenLink ? url.deletingLastPathComponent() : url, missingAllowed: missingAllowed)
        guard !relative.lowercased().contains("keychain"), !relative.lowercased().contains("tcc"), !relative.contains("/Orbit/") else { throw MaintenanceFailure.denied("此项目受保护。") }
    }
    private func requireClosed(_ url: URL) async throws {
        if !checksOpenFiles { return }
        var paths = [url.path]
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            try Self.noLinks(URL(fileURLWithPath: url.path + suffix)); paths.append(url.path + suffix)
        }
        let result = await Self.command("/usr/sbin/lsof", ["-t", "--"] + paths, timeout: 5)
        guard result.exitCode == 1, result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MaintenanceFailure.busy }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            try Self.noLinks(URL(fileURLWithPath: url.path + suffix))
            if suffix == "-wal", ((try? fm.attributesOfItem(atPath: url.path + suffix)[.size] as? Int64) ?? 0) > 0 { throw MaintenanceFailure.busy }
        }
    }
    private func ensureStorage() throws {
        try Self.noLinks(storage.deletingLastPathComponent(), missingAllowed: true)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.noLinks(storage)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.path)
    }
    private func acquireLock() throws -> Int32 {
        let fd = open(storage.appendingPathComponent("mutation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MaintenanceFailure.busy }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw MaintenanceFailure.busy }
        return fd
    }
    private func load() throws -> [MaintenanceRecoveryRecord] {
        guard fm.fileExists(atPath: journal.path) else { return [] }
        try Self.noLinks(journal)
        return try JSONDecoder().decode([MaintenanceRecoveryRecord].self, from: Data(contentsOf: journal))
    }
    private func save(_ records: [MaintenanceRecoveryRecord]) throws {
        try Self.noLinks(journal, missingAllowed: true)
        try JSONEncoder().encode(records).write(to: journal, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    private func result(_ task: MaintenanceTask, _ status: MaintenanceStatus, _ text: String, _ start: TimeInterval) -> MaintenanceResult {
        MaintenanceResult(task: task, status: status, message: text, output: "", elapsedSeconds: ProcessInfo.processInfo.systemUptime - start)
    }
    private static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) async -> MaintenanceCommandResult {
        await MaintenanceService.execute(MaintenanceCommand(executable: executable, arguments: arguments, timeoutSeconds: timeout))
    }
    private static func sqlite(_ url: URL, _ sql: String, readonly: Bool, timeout: TimeInterval = 15) async -> MaintenanceCommandResult {
        do { try noLinks(url) } catch { return MaintenanceCommandResult(exitCode: 1, output: error.localizedDescription) }
        return await command("/usr/bin/sqlite3", ["-batch", "-bail", "-cmd", ".timeout 1000"] + (readonly ? ["-readonly"] : []) + [url.path, sql], timeout: timeout)
    }
    private static func scalar(_ url: URL, _ sql: String) async -> Int64? {
        let result = await sqlite(url, sql, readonly: true)
        return result.exitCode == 0 ? Int64(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }
    private static func readPlist(_ url: URL) throws -> [String: Any] {
        try noLinks(url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size < 8_000_000 else { throw MaintenanceFailure.limit }
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else { throw MaintenanceFailure.denied("列表格式不可识别。") }
        return value
    }
    private static func validPlist(_ url: URL) -> Bool {
        guard (try? noLinks(url)) != nil, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size < 8_000_000, let data = try? Data(contentsOf: url) else { return false }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil
    }
    private static func newestModification(_ url: URL) throws -> Date {
        try noLinks(url)
        var newest = Date.distantPast, count = 0
        let started = ProcessInfo.processInfo.systemUptime
        func inspect(_ file: URL) throws {
            count += 1
            guard count < 20_000, ProcessInfo.processInfo.systemUptime - started < 5 else { throw MaintenanceFailure.limit }
            try noLinks(file)
            newest = max(newest, try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date())
        }
        try inspect(url)
        var failed = false
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], errorHandler: { _, _ in failed = true; return false })
        while let child = enumerator?.nextObject() as? URL { try inspect(child) }
        guard !failed else { throw MaintenanceFailure.changed }
        return newest
    }
    private static func thirdParty(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+){2,}$", options: .regularExpression) != nil && !name.hasPrefix("com.apple.") && !name.hasPrefix("System.") && !name.lowercased().hasPrefix("com.orbitmac.orbit")
    }
    static func loginFindings(_ output: String, home: URL) -> [String] {
        var name = "登录项", findings: [String] = [], checked = 0
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Name:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("URL:"), let url = URL(string: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)), url.isFileURL else { continue }
            checked += 1
            if url.path.hasPrefix("/Volumes/") {
                findings.append(name + "：外置磁盘项目，保留并在系统设置核对。")
            } else if (url.path.hasPrefix("/Applications/") || url.path.hasPrefix(home.appendingPathComponent("Applications").path + "/")), !FileManager.default.fileExists(atPath: url.path) {
                findings.append(name + "：目标已不存在，在系统登录项中停用或移除。\n" + url.path)
            }
        }
        return findings.isEmpty ? ["已检查 \(checked) 个可解析的文件目标，未发现可确认失效的应用登录项。"] : findings
    }
    private static func protectedService(_ text: String) -> Bool {
        ["mole", "orbit", "jamf", "mdm", "crowdstrike", "sentinel", "defender", "tailscale", "clash", "surge", "wireguard", "vpn", "security", "sophos"].contains { text.lowercased().contains($0) }
    }
    private static func noLinks(_ url: URL, missingAllowed: Bool = false) throws {
        var cursor = url
        while cursor.path != "/" {
            var st = stat()
            if lstat(cursor.path, &st) != 0 {
                if missingAllowed, errno == ENOENT { cursor.deleteLastPathComponent(); continue }
                throw MaintenanceFailure.denied("路径不可读：" + cursor.path)
            }
            guard st.st_mode & S_IFMT != S_IFLNK else { throw MaintenanceFailure.denied("不处理符号链接：" + cursor.path) }
            cursor.deleteLastPathComponent()
        }
    }
    private static func fingerprint(_ url: URL, allowLink: Bool = false) throws -> String {
        try noLinks(allowLink ? url.deletingLastPathComponent() : url)
        var hash = SHA256()
        let start = ProcessInfo.processInfo.systemUptime
        var files = 0, bytes: Int64 = 0
        func feed(_ current: URL) throws {
            files += 1
            guard files <= 20_000, ProcessInfo.processInfo.systemUptime - start < 15 else { throw MaintenanceFailure.limit }
            var st = stat()
            guard lstat(current.path, &st) == 0 else { throw MaintenanceFailure.changed }
            if !(allowLink && current == url) { try noLinks(current) }
            let relative = String(current.path.dropFirst(url.path.count))
            hash.update(data: Data("\(relative)|\(st.st_mode)|\(st.st_uid)|\(st.st_size)|\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec)".utf8))
            if st.st_mode & S_IFMT == S_IFLNK {
                guard allowLink, current == url else { throw MaintenanceFailure.denied("目录内含符号链接，已保留。") }
                hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: current.path).utf8))
            } else if st.st_mode & S_IFMT == S_IFREG {
                guard st.st_nlink == 1 else { throw MaintenanceFailure.denied("硬链接文件已保留。") }
                bytes += st.st_size
                guard bytes <= 2_000_000_000 else { throw MaintenanceFailure.limit }
                let handle = try FileHandle(forReadingFrom: current); defer { try? handle.close() }
                while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
                    guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime - start < 15 else { throw MaintenanceFailure.limit }
                    hash.update(data: data)
                }
            } else if st.st_mode & S_IFMT != S_IFDIR { throw MaintenanceFailure.denied("不支持此文件类型。") }
        }
        try feed(url)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            var unreadable = false
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in unreadable = true; return false }) else { throw MaintenanceFailure.changed }
            var children: [URL] = []
            while let child = enumerator.nextObject() as? URL {
                if children.count >= 20_000 { throw MaintenanceFailure.limit }
                var st = stat()
                guard lstat(child.path, &st) == 0, st.st_mode & S_IFMT != S_IFLNK else { throw MaintenanceFailure.denied("目录内含符号链接或不可读文件，已保留。") }
                children.append(child)
            }
            guard !unreadable else { throw MaintenanceFailure.denied("目录未完整读取，已保留。") }
            for child in children.sorted(by: { $0.path < $1.path }) { try feed(child) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
