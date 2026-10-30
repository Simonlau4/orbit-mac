import Foundation
import Darwin

public enum AIInventoryDisposition: String, Codable, Sendable {
    case candidate, running, recent, currentVersion, reviewOnly, unavailable
}

public enum AIInventoryRootState: String, Codable, Sendable { case missing, available, partial, unavailable, alias }

public struct AIInventoryRoot: Codable, Sendable {
    public let tool: AITool
    public let kind: AICleanupKind
    public let url: URL
    public let state: AIInventoryRootState
    public let aliasOf: URL?
}

public struct AIInventoryFile: Codable, Hashable, Sendable {
    public let url: URL
    public let itemID: String
    public let device: UInt64
    public let inode: UInt64
    public let bytes: Int64
    public let allocatedBytes: Int64
    public var identity: String { "\(device):\(inode)" }
}

public struct AIInventoryItem: Identifiable, Codable, Sendable {
    public var id: String { "\(tool.rawValue):\(kind.rawValue):\(url.path)" }
    public let tool: AITool
    public let kind: AICleanupKind
    public let url: URL
    public let rootURL: URL
    public let bytes: Int64
    public let fileCount: Int
    public let disposition: AIInventoryDisposition
    public let reason: String
    public let isPartial: Bool
}

/// Metadata inventory only. Candidate entries still require the existing AI review and fresh admission.
public struct AIInventoryScan: Codable, Sendable {
    public let items: [AIInventoryItem]
    public let roots: [AIInventoryRoot]
    public let metadataFiles: [AIInventoryFile]
    public let issues: [CleanupScanIssue]
    public let visitedEntries: Int
    public let isPartial: Bool
    public init(items: [AIInventoryItem] = [], roots: [AIInventoryRoot] = [], metadataFiles: [AIInventoryFile] = [],
                issues: [CleanupScanIssue] = [], visitedEntries: Int = 0, isPartial: Bool = false) {
        self.items = items; self.roots = roots; self.metadataFiles = metadataFiles; self.issues = issues
        self.visitedEntries = visitedEntries; self.isPartial = isPartial
    }
    public var totalBytes: Int64 { metadataFiles.reduce(0) { $0 + $1.bytes } }
    public var candidateBytes: Int64 { items.filter { $0.disposition == .candidate }.reduce(0) { $0 + $1.bytes } }
    public var retainedBytes: Int64 { totalBytes - candidateBytes }
    public var scannedFiles: Int { metadataFiles.count }
}

public actor AIInventoryScanner {
    private let home: URL
    private let now: Date
    private let maximumFiles: Int
    private let timeLimit: TimeInterval
    private let activity: AIActivityProvider

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(),
                maximumFiles: Int = 100_000, timeLimit: TimeInterval = 20,
                activity: @escaping AIActivityProvider = { AIActivity.runningTools() }) {
        self.home = CleanupPaths.normalized(home); self.now = now
        self.maximumFiles = maximumFiles; self.timeLimit = timeLimit; self.activity = activity
    }

    /// Exclude these exact roots from ordinary scanning even when this inventory is partial or unavailable.
    public nonisolated static func coveredRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let home = CleanupPaths.normalized(home)
        return (AIInventoryPolicy.cacheRoots.map { $0.1 } + [".claude/Cache"] + AIInventoryPolicy.versionRoots.map(\.root))
            .map { home.appendingPathComponent($0) }
    }

    public func scan() async -> AIInventoryScan {
        let state = AIInventoryState(maximum: maximumFiles, seconds: timeLimit)
        let running = activity()
        var roots: [AIInventoryRoot] = [], items: [AIInventoryItem] = []
        var rootIdentities: [String: URL] = [:]

        func readRoot(_ tool: AITool, _ kind: AICleanupKind, _ root: URL,
                      body: (stat) throws -> Void) {
            var info = stat()
            guard lstat(root.path, &info) == 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR {
                    roots.append(AIInventoryRoot(tool: tool, kind: kind, url: root, state: .missing, aliasOf: nil))
                } else {
                    state.record(NSError(domain: NSPOSIXErrorDomain, code: Int(code)), at: root)
                    roots.append(AIInventoryRoot(tool: tool, kind: kind, url: root, state: .unavailable, aliasOf: nil))
                    items.append(state.unavailable(tool, kind, root))
                }
                return
            }
            let identity = "\(info.st_dev):\(info.st_ino)"
            if let previous = rootIdentities[identity] {
                roots.append(AIInventoryRoot(tool: tool, kind: kind, url: root, state: .alias, aliasOf: previous)); return
            }
            do {
                try state.check(); try CleanupPaths.noSymlinks(root)
                guard info.st_mode & S_IFMT == S_IFDIR else { throw AICleanupError.unsafe(root.path) }
                rootIdentities[identity] = root
                let before = state.failureCount, itemOffset = items.count
                try body(info)
                roots.append(AIInventoryRoot(tool: tool, kind: kind, url: root,
                    state: state.failureCount == before && !items.dropFirst(itemOffset).contains(where: \.isPartial) ? .available : .partial, aliasOf: nil))
            } catch {
                state.record(error, at: root)
                let measured = items.contains { $0.rootURL.path == root.path }
                roots.append(AIInventoryRoot(tool: tool, kind: kind, url: root, state: measured ? .partial : .unavailable, aliasOf: nil))
                if !measured { items.append(state.unavailable(tool, kind, root)) }
            }
        }

        // Read the small, known version inventory before potentially large active caches consume the budget.
        for location in AIInventoryPolicy.versionRoots {
            let root = home.appendingPathComponent(location.root)
            readRoot(location.tool, .oldVersion, root) { _ in
                let children = try state.children(root)
                let known = try children.filter { child in
                    guard AIInventoryPolicy.versionComponents(child.lastPathComponent, tool: location.tool) != nil else { return false }
                    var info = stat()
                    guard lstat(child.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    let type = info.st_mode & S_IFMT
                    return type == S_IFDIR || (location.tool == .claude && type == S_IFREG)
                }
                let knownPaths = Set(known.map(\.path))
                var preserved = Set<String>(), verified = true
                do {
                    preserved = try AIInventoryPolicy.preservedVersions(known, tool: location.tool,
                        root: location.root, entry: location.entry, home: home)
                } catch { verified = false; state.record(error, at: root) }
                for child in children {
                    try state.check()
                    let recognized = knownPaths.contains(child.path)
                    let force: AIInventoryDisposition? = !recognized || !verified ? .reviewOnly
                        : preserved.contains(child.path) ? .currentVersion : nil
                    let detail = !verified ? "无法核对当前版本入口，保留" : !recognized ? "版本入口或未识别目录，保留" : "当前或最新版本，保留"
                    items.append(state.measure(child, root: root, tool: location.tool, kind: .oldVersion,
                        now: now, running: running.contains(location.tool), forced: force,
                        forcedReason: detail, traverse: recognized, requiresDirectory: location.tool == .cursor))
                }
            }
            await Task.yield()
        }
        for (tool, suffix) in AIInventoryPolicy.cacheRoots + [(.claude, ".claude/Cache")] {
            let root = home.appendingPathComponent(suffix)
            readRoot(tool, .cache, root) { _ in
                for child in try state.children(root) {
                    try state.check()
                    items.append(state.measure(child, root: root, tool: tool, kind: .cache, now: now,
                        running: running.contains(tool), forced: suffix == ".claude/Cache" ? .reviewOnly : nil,
                        forcedReason: "额外大小写路径需在 AI 专门页面核对", traverse: true))
                }
            }
            await Task.yield()
        }
        return AIInventoryScan(items: items, roots: roots, metadataFiles: state.files, issues: state.issues,
            visitedEntries: state.visited, isPartial: state.failureCount > 0 || items.contains(where: \.isPartial))
    }
}

private final class AIInventoryState {
    let maximum: Int
    let deadline: TimeInterval
    var visited = 0
    var files: [AIInventoryFile] = []
    var identities = Set<String>()
    var issues: [CleanupScanIssue] = []
    var failureCount = 0

    init(maximum: Int, seconds: TimeInterval) {
        self.maximum = max(0, maximum); deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds)
    }
    func check() throws {
        if Task<Never, Never>.isCancelled { throw AICleanupError.cancelled }
        if visited >= maximum || ProcessInfo.processInfo.systemUptime >= deadline { throw AICleanupError.budget }
    }
    func visit() throws { try check(); visited += 1 }
    func record(_ error: Error, at url: URL) {
        failureCount += 1
        let issue: CleanupScanIssue
        switch error {
        case AICleanupError.budget: issue = CleanupScanIssue(kind: .limit, path: url.path, message: "AI 占用统计达到条目或时间上限，仅显示已核对范围")
        case AICleanupError.cancelled: issue = CleanupScanIssue(kind: .cancelled, path: url.path, message: "AI 占用统计已取消，仅显示已核对范围")
        default: issue = .reading(error, at: url)
        }
        if issues.count < 64 { if !issues.contains(issue) { issues.append(issue) } }
        else if issue.kind == .limit || issue.kind == .cancelled, !issues.contains(where: { $0.kind == issue.kind }) { issues[63] = issue }
    }
    func unavailable(_ tool: AITool, _ kind: AICleanupKind, _ url: URL) -> AIInventoryItem {
        AIInventoryItem(tool: tool, kind: kind, url: url, rootURL: url, bytes: 0, fileCount: 0,
            disposition: .unavailable, reason: "尚未完成读取，占用未知", isPartial: true)
    }
    func children(_ directory: URL) throws -> [URL] {
        let fd = open(directory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard let stream = fdopendir(fd) else { let code = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        defer { closedir(stream) }
        var urls: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name != "." && name != ".." else { continue }
            try visit(); urls.append(directory.appendingPathComponent(name))
        }
        return urls.sorted { $0.path < $1.path }
    }
    func measure(_ url: URL, root: URL, tool: AITool, kind: AICleanupKind, now: Date,
                 running: Bool, forced: AIInventoryDisposition?, forcedReason: String,
                 traverse: Bool, requiresDirectory: Bool = false) -> AIInventoryItem {
        let itemID = "\(tool.rawValue):\(kind.rawValue):\(url.path)"
        var bytes: Int64 = 0, count = 0, latest = Date.distantPast
        var partial = false, protected = false, reason = forced == nil ? "" : forcedReason
        var pending = [url], current = url
        do {
            while let file = pending.popLast() {
                current = file
                try visit()
                var info = stat()
                guard lstat(file.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let type = info.st_mode & S_IFMT
                latest = max(latest, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
                if type == S_IFLNK { protected = true; reason = "符号链接保留，不读取目标"; continue }
                if AIInventoryPolicy.protectedNames.contains(file.lastPathComponent.lowercased()), !AIInventoryPolicy.insideApplication(file, root: url) {
                    protected = true; partial = true; reason = "记忆、技能、设置或凭据保留，不遍历"; continue
                }
                if file.path == url.path, requiresDirectory, type != S_IFDIR {
                    protected = true; reason = "无法确认旧版本目录，保留"
                }
                if type == S_IFDIR {
                    guard traverse else { partial = true; protected = true; continue }
                    pending.append(contentsOf: try children(file).reversed())
                } else if type == S_IFREG {
                    let identity = "\(info.st_dev):\(info.st_ino)"
                    if info.st_nlink != 1 { protected = true; reason = "共享硬链接保留" }
                    if identities.insert(identity).inserted {
                        let size = max(0, Int64(info.st_size)); bytes += size; count += 1
                        files.append(AIInventoryFile(url: file, itemID: itemID, device: UInt64(bitPattern: Int64(info.st_dev)),
                            inode: UInt64(info.st_ino), bytes: size, allocatedBytes: max(0, Int64(info.st_blocks)) * 512))
                    }
                } else { protected = true; reason = "特殊文件保留" }
            }
        } catch { partial = true; reason = "占用尚未统计完整，保留"; record(error, at: current) }
        let disposition: AIInventoryDisposition
        if partial { disposition = .reviewOnly; if reason.isEmpty { reason = "占用仅统计了一部分，保留" } }
        else if protected { disposition = .reviewOnly }
        else if let forced { disposition = forced }
        else if running { disposition = .running; reason = "检测到可能使用此数据的应用或命令行进程，保留" }
        else if latest > now.addingTimeInterval(-7 * 86400) { disposition = .recent; reason = "最近 7 天仍有文件活动，保留" }
        else { disposition = .candidate; reason = "可进入 AI 专门审阅；统一结果默认未选" }
        return AIInventoryItem(tool: tool, kind: kind, url: url, rootURL: root, bytes: bytes, fileCount: count,
            disposition: disposition, reason: reason, isPartial: partial)
    }
}
