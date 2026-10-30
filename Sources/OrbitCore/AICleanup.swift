import Foundation
import CryptoKit
import Darwin

public enum AITool: String, Codable, CaseIterable, Hashable, Sendable {
    case codex, claude, cursor, pi, ollama
    public var title: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .cursor: return "Cursor"; case .pi: return "Pi"; case .ollama: return "Ollama" }
    }
}

public enum AICleanupKind: String, Codable, CaseIterable, Hashable, Sendable {
    case cache, oldVersion, session, archive, worktree, model, database, tool, databaseSession, orphanedVisualization
    public var title: String {
        switch self {
        case .cache: return "缓存和日志"
        case .oldVersion: return "旧版本"
        case .session: return "历史对话"
        case .archive: return "本地历史副本"
        case .worktree: return "已完成的 Worktree"
        case .model: return "旧的本地模型"
        case .database: return "数据库压缩"
        case .tool: return "个人 CLI 程序"
        case .databaseSession: return "数据库历史对话"
        case .orphanedVisualization: return "已删除会话的图片"
        }
    }
}

public struct AICleanupCandidate: Identifiable, Codable, Hashable, Sendable {
    public var id: String { kind.rawValue + ":" + url.path + (cursorSession.map { ":" + $0.composerID } ?? "") }
    public var conversationID: String? { cursorSession?.composerID ?? orphanedThreadID ?? threadID }
    public var relatedConversationIDs: [String] { cursorSession?.referencedIDs.sorted() ?? [] }
    public let tool: AITool
    public let kind: AICleanupKind
    public let url: URL
    public let title: String
    public let detail: String
    public let bytes: Int64
    public let modifiedAt: Date
    fileprivate let sources: [URL]
    fileprivate let signatures: [String: String]
    fileprivate let dependencies: [String: String]
    fileprivate let codexDatabase: URL?
    fileprivate let threadID: String?
    fileprivate let gitCommonDirectory: URL?
    fileprivate let cursorSession: AICursorSession?
    fileprivate let orphanedThreadID: String?
}

// Older 0.3 recovery records do not contain dependency tracking or the new database/image metadata.
// Keep the stored source signatures mandatory; default only newly introduced optional state.
extension AICleanupCandidate {
    private enum CodingKeys: String, CodingKey {
        case tool, kind, url, title, detail, bytes, modifiedAt, sources, signatures, dependencies
        case codexDatabase, threadID, gitCommonDirectory, cursorSession, orphanedThreadID
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tool = try values.decode(AITool.self, forKey: .tool)
        kind = try values.decode(AICleanupKind.self, forKey: .kind)
        url = try values.decode(URL.self, forKey: .url)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decode(String.self, forKey: .detail)
        bytes = try values.decode(Int64.self, forKey: .bytes)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        sources = try values.decode([URL].self, forKey: .sources)
        signatures = try values.decode([String: String].self, forKey: .signatures)
        dependencies = try values.decodeIfPresent([String: String].self, forKey: .dependencies) ?? [:]
        codexDatabase = try values.decodeIfPresent(URL.self, forKey: .codexDatabase)
        threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
        gitCommonDirectory = try values.decodeIfPresent(URL.self, forKey: .gitCommonDirectory)
        cursorSession = try values.decodeIfPresent(AICursorSession.self, forKey: .cursorSession)
        orphanedThreadID = try values.decodeIfPresent(String.self, forKey: .orphanedThreadID)
    }
}

public struct AIRetainedItem: Identifiable, Sendable {
    public var id: String { tool.rawValue + ":" + kind.rawValue + ":" + url.path + (conversationID.map { ":" + $0 } ?? "") }
    public let conversationID: String?
    public let tool: AITool
    public let kind: AICleanupKind
    public let url: URL
    public let reason: String
}

public struct AICleanupScan: Sendable {
    public let items: [AICleanupCandidate]
    public let retained: [AIRetainedItem]
    public let warnings: [String]
    public let isPartial: Bool
    public let scannedFiles: Int
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

public enum AICleanupError: LocalizedError {
    case unsafe(String), changed(String), busy(String), budget, command(String), corruptHistory, conflict(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .unsafe(let p): return "保留不在明确清理范围内的文件：\(p)"
        case .changed(let p): return "文件已改变，请重新扫描：\(p)"
        case .busy(let p): return "暂时无法处理，请结束相关进程或任务后重试：\(p)"
        case .budget: return "扫描达到时间或文件数上限；仅显示已核对的范围。"
        case .command(let message): return message
        case .cancelled: return "操作已取消，已完成的步骤保留在恢复记录中。"
        case .corruptHistory: return "AI 恢复记录无法读取，已停止操作。"
        case .conflict(let p): return "原位置已有文件或数据库已有新内容，未覆盖：\(p)"
        }
    }
}

public typealias AIActivityProvider = @Sendable () -> Set<AITool>

/// Activity is checked at scan time and again before every mutation. No session content is read.
public enum AIActivity {
    public static func runningTools() -> Set<AITool> {
        guard let output = try? AICommand.run("/bin/ps", ["-ax", "-o", "comm="], timeout: 3) else { return Set(AITool.allCases) }
        var result = Set<AITool>()
        for line in output.split(separator: "\n") {
            let path = String(line).lowercased()
            let name = URL(fileURLWithPath: path).lastPathComponent
            if name == "codex" || path.contains("codex.app/") || path.contains("chatgpt.app/") { result.insert(.codex) }
            if name == "claude" || path.contains("claude.app/") { result.insert(.claude) }
            if name == "cursor-agent" || path.contains("cursor.app/") { result.insert(.cursor) }
            if name == "pi" { result.insert(.pi) }
            // Script-based CLIs can appear only as Node in comm; conservatively keep their data while a runtime exists.
            if name == "node" || name == "nodejs" { result.formUnion([.pi, .cursor]) }
            if name == "ollama" || path.contains("ollama.app/") { result.insert(.ollama) }
        }
        return result
    }
}

public actor AICleanupScanner {
    private let home: URL
    private let now: Date
    private let maximumFiles: Int
    private let timeLimit: TimeInterval
    private let activity: AIActivityProvider

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(),
                maximumFiles: Int = 100_000, timeLimit: TimeInterval = 30,
                activity: @escaping AIActivityProvider = { AIActivity.runningTools() }) {
        self.home = AIPaths.normalized(home); self.now = now
        self.maximumFiles = maximumFiles; self.timeLimit = timeLimit; self.activity = activity
    }

    /// nil preserves all sessions. Every returned candidate is unselected; the UI owns explicit selection.
    public func scan(sessionRetentionDays: Int? = nil, modelAgeDays: Int = 30) async -> AICleanupScan {
        let budget = AIBudget(maximum: maximumFiles, seconds: timeLimit)
        let running = activity()
        var items: [AICleanupCandidate] = [], retained: [AIRetainedItem] = [], warnings: [String] = []
        var partial = false
        func warn(_ error: Error) {
            if warnings.count < 12 { warnings.append(error.localizedDescription) }
            partial = true
        }
        func keep(_ tool: AITool, _ kind: AICleanupKind, _ url: URL, _ reason: String, conversationID: String? = nil) {
            if retained.count < 500 { retained.append(AIRetainedItem(conversationID: conversationID, tool: tool, kind: kind, url: url, reason: reason)) }
            else {
                let message = "保留项只展示前 500 条；其他保留文件均未处理。"
                if warnings.count < 12, !warnings.contains(message) { warnings.append(message) }
                partial = true
            }
        }
        func add(_ tool: AITool, _ kind: AICleanupKind, _ url: URL, days: Int, detail: String,
                 sources: [URL]? = nil, dependencies: [URL] = [], database: URL? = nil, threadID: String? = nil, git: URL? = nil, orphanedThreadID: String? = nil) throws {
            try budget.check()
            if running.contains(tool) { keep(tool, kind, url, "检测到可能使用数据的应用或命令行进程，保留；退出相关工具后重新扫描"); return }
            let urls = sources ?? [url]
            var stamps: [String: String] = [:], bytes: Int64 = 0
            var latest = Date.distantPast
            for source in urls {
                try AIPaths.admit(source, kind: kind, home: home)
                let stamp = try AIPaths.snapshot(source, budget: budget, allowFinalLink: kind == .tool)
                stamps[source.path] = stamp.signature; bytes += stamp.bytes; latest = max(latest, stamp.latest)
            }
            var dependencyStamps: [String: String] = [:]
            for dependency in dependencies {
                try AIPaths.admit(dependency, kind: .model, home: home)
                dependencyStamps[dependency.path] = try AIPaths.snapshot(dependency, budget: budget, ignoringRootChange: true).signature
            }
            guard latest <= now.addingTimeInterval(-Double(max(0, days)) * 86400) else {
                keep(tool, kind, url, "最近仍有文件活动"); return
            }
            items.append(AICleanupCandidate(tool: tool, kind: kind, url: url,
                title: kind == .session ? "\(tool.title) · \(url.deletingPathExtension().lastPathComponent)" : url.lastPathComponent,
                detail: detail, bytes: bytes, modifiedAt: latest, sources: urls, signatures: stamps,
                dependencies: dependencyStamps, codexDatabase: database, threadID: threadID, gitCommonDirectory: git, cursorSession: nil, orphanedThreadID: orphanedThreadID))
        }
        do {
            for (tool, suffix) in AIPaths.cacheRoots {
                let root = home.appendingPathComponent(suffix)
                guard AIPaths.exists(root) else { continue }
                do {
                    try AIPaths.noSymlinks(root)
                    for file in try AIPaths.children(root) {
                        do { try add(tool, .cache, file, days: 7, detail: "只处理明确的缓存或日志，保留会话、设置、记忆与技能。") }
                        catch { if case AICleanupError.budget = error { throw error }; warn(error) }
                    }
                } catch { if case AICleanupError.budget = error { throw error }; warn(error) }
                await Task.yield()
            }
            for location in AIPaths.cliVersionRoots {
                let versions = home.appendingPathComponent(location.root)
                guard AIPaths.exists(versions) else { continue }
                do {
                    var files: [URL] = []
                    for file in try AIPaths.children(versions) {
                        try budget.visit()
                        let metadata = try AIPaths.stat(file, allowLink: true)
                        if metadata.value.st_mode & S_IFMT == S_IFLNK {
                            keep(location.tool, .oldVersion, file, "符号链接入口保留"); continue
                        }
                        if AIPaths.versionComponents(file.lastPathComponent, tool: location.tool) != nil {
                            if location.tool == .cursor && !metadata.isDirectory { keep(location.tool, .oldVersion, file, "无法确认旧版本目录，保留"); continue }
                            files.append(file)
                        }
                    }
                    let preserved = try AIPaths.preservedVersions(files, location: location, home: home)
                    for file in files {
                        if preserved.contains(file.path) { keep(location.tool, .oldVersion, file, "当前或最新版本"); continue }
                        try add(location.tool, .oldVersion, file, days: 7, detail: "保留当前入口、current/latest 指向与最新版本；仅移走这一份旧程序。")
                    }
                } catch {
                    if case AICleanupError.budget = error { throw error }
                    if case AICleanupError.cancelled = error { throw error }
                    keep(location.tool, .oldVersion, versions, "无法确认当前版本，保留：" + error.localizedDescription)
                }
            }
            for (tool, name) in AIPaths.toolEntries {
                let entry = home.appendingPathComponent(".local/bin/" + name)
                guard AIPaths.exists(entry) else { continue }
                let isLink = (try? AIPaths.stat(entry, allowLink: true).value.st_mode & S_IFMT == S_IFLNK) == true
                do { try add(tool, .tool, entry, days: 90,
                    detail: isLink ? "超过 90 天没有文件改动，需人工核对使用情况。仅移走个人命令入口，程序包、会话和设置保留。" : "超过 90 天没有文件改动，需人工核对使用情况。移走个人 CLI 程序，保留会话与设置。") }
                catch { if case AICleanupError.budget = error { throw error }; warn(error) }
            }
            let codexDB = try AIPaths.codexDatabase(home)
            for (tool, suffix, kind) in AIPaths.sessionRoots {
                let root = home.appendingPathComponent(suffix)
                guard AIPaths.exists(root) else { continue }
                try AIPaths.noSymlinks(root)
                guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
                while let file = iterator.nextObject() as? URL {
                    try budget.visit()
                    let name = file.lastPathComponent.lowercased()
                    if AIPaths.protectedNames.contains(name) { iterator.skipDescendants(); continue }
                    guard AIPaths.isSession(file, root: root, tool: tool) else { continue }
                    guard let days = sessionRetentionDays, days > 0 else {
                        keep(tool, kind, file, "尚未选择对话保留天数"); continue
                    }
                    if running.contains(tool) { keep(tool, kind, file, "检测到可能使用数据的应用或命令行进程，保留；退出相关工具后重新扫描"); continue }
                    var threadID: String?
                    if tool == .codex {
                        threadID = AIPaths.codexThreadID(file)
                        guard let database = codexDB, let threadID,
                              try AIPaths.codexHasThread(database, id: threadID, path: file.path) else {
                            keep(tool, kind, file, "无法核对 Codex 会话索引，保留原文件"); continue
                        }
                    }
                    do { try add(tool, kind, file, days: days, detail: kind == .archive ? "仅本地记录副本；可能是唯一副本，恢复前需退出工具。" : "对话会从本机移出；恢复副本保留在 Orbit 中。", database: tool == .codex ? codexDB : nil, threadID: threadID) }
                    catch { if case AICleanupError.budget = error { throw error }; warn(error) }
                }
                await Task.yield()
            }
            for (tool, suffix) in AIPaths.worktreeRoots {
                let root = home.appendingPathComponent(suffix)
                guard AIPaths.exists(root) else { continue }
                try AIPaths.noSymlinks(root)
                var worktrees: [URL] = []
                for child in try AIPaths.children(root) {
                    try budget.visit()
                    if AIPaths.exists(child.appendingPathComponent(".git")) { worktrees.append(child) }
                    else if (try? AIPaths.stat(child).isDirectory) == true {
                        worktrees += try AIPaths.children(child).filter { AIPaths.exists($0.appendingPathComponent(".git")) }
                    }
                }
                for tree in worktrees {
                    do {
                        let common = try AIPaths.safeWorktree(tree, now: now)
                        try add(tool, .worktree, tree, days: 1, detail: "已核对工作区无改动、无忽略文件且提交已在远端；移动后保留分支和提交。", git: common)
                    } catch {
                        keep(tool, .worktree, tree, error.localizedDescription)
                    }
                }
            }
            let models = home.appendingPathComponent(".ollama/models")
            if AIPaths.exists(models) {
                let manifests = try AIPaths.ollamaManifests(home, budget: budget)
                for manifest in manifests {
                    let exclusive = manifest.blobs.filter { blob in manifests.filter { $0.blobs.contains(blob) }.count == 1 }
                    do { try add(.ollama, .model, manifest.url, days: max(30, modelAgeDays),
                                 detail: "根据文件活动时间列出的旧模型，需人工核对实际使用情况。共享权重保留，恢复副本仍占磁盘。",
                                 sources: [manifest.url] + exclusive, dependencies: manifest.blobs.filter { !exclusive.contains($0) }) }
                    catch { if case AICleanupError.budget = error { throw error }; warn(error) }
                }
            }
            let cursorDatabase = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            if AIPaths.exists(cursorDatabase) {
                if running.contains(.cursor) { keep(.cursor, .databaseSession, cursorDatabase, "检测到可能使用数据的应用或命令行进程，对话全部保留；退出相关工具后重新扫描") }
                else if let days = sessionRetentionDays, days > 0 {
                    do {
                        let catalog = try AIPaths.cursorSessions(home, budget: budget)
                        let signature = try AIPaths.snapshot(cursorDatabase, budget: budget).signature
                        for plan in catalog {
                            try budget.visit()
                            let modified = Date(timeIntervalSince1970: Double(plan.updatedAtMilliseconds) / 1000)
                            if let reason = plan.eligibility { keep(.cursor, .databaseSession, cursorDatabase, reason, conversationID: plan.composerID); continue }
                            if modified > now.addingTimeInterval(-Double(days) * 86400) { continue }
                            items.append(AICleanupCandidate(tool: .cursor, kind: .databaseSession, url: cursorDatabase,
                                title: "Cursor · " + plan.composerID, detail: "\(plan.rowCount) 条会话及专属记录；共享内容 blob 与内联编辑数据保留。有关系的会话须一并选择。",
                                bytes: plan.bytes, modifiedAt: modified, sources: [], signatures: [cursorDatabase.path: signature], dependencies: [:],
                                codexDatabase: nil, threadID: nil, gitCommonDirectory: nil, cursorSession: plan, orphanedThreadID: nil))
                        }
                    } catch { keep(.cursor, .databaseSession, cursorDatabase, error.localizedDescription); warn(error) }
                } else { keep(.cursor, .databaseSession, cursorDatabase, "尚未选择对话保留天数") }
            }
            let visualizations = home.appendingPathComponent(".codex/visualizations")
            if AIPaths.exists(visualizations) {
                if running.contains(.codex) { keep(.codex, .orphanedVisualization, visualizations, "检测到可能使用数据的应用或命令行进程，图片全部保留；退出相关工具后重新扫描") }
                else {
                    do {
                        let references = try AIPaths.codexReferences(home, budget: budget)
                        try AIPaths.noSymlinks(visualizations)
                        if let iterator = FileManager.default.enumerator(at: visualizations, includingPropertiesForKeys: nil) {
                            while let image = iterator.nextObject() as? URL {
                                try budget.visit()
                                if AIPaths.protectedNames.contains(image.lastPathComponent.lowercased()) || image.lastPathComponent.lowercased() == "attachments" { iterator.skipDescendants(); continue }
                                guard let id = AIPaths.visualizationThreadID(image, home: home) else { continue }
                                guard !(try AIPaths.stat(image).isDirectory) else { iterator.skipDescendants(); continue }
                                if try references.references(id: id, image: image) { keep(.codex, .orphanedVisualization, image, "仍有会话或附件索引关联"); continue }
                                try add(.codex, .orphanedVisualization, image, days: max(30, sessionRetentionDays ?? 30),
                                    detail: "会话数据库、索引和会话文件均无关联；仅移动这一图片，保留其他文件。", orphanedThreadID: id)
                            }
                        }
                    } catch { keep(.codex, .orphanedVisualization, visualizations, error.localizedDescription); warn(error) }
                }
            }
            for (tool, url) in try AIPaths.databases(home) where AIPaths.exists(url) {
                do {
                    if running.contains(tool) { keep(tool, .database, url, "检测到可能使用数据库的应用或命令行进程，保留；退出相关工具后重新扫描"); continue }
                    guard try AIPaths.sqlite(url, "PRAGMA quick_check;").trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                        keep(tool, .database, url, "数据库完整性检查未通过"); continue
                    }
                    try add(tool, .database, url, days: 0, detail: "保留所有记录，仅压缩 SQLite 空闲页；操作前保存完整恢复副本。")
                } catch { if case AICleanupError.budget = error { throw error }; warn(error) }
            }
        } catch { warn(error) }
        return AICleanupScan(items: items.sorted { ($0.tool.rawValue, $0.kind.rawValue, $0.id) < ($1.tool.rawValue, $1.kind.rawValue, $1.id) },
                             retained: retained, warnings: warnings, isPartial: partial, scannedFiles: budget.count)
    }
}

public enum AIRecoveryState: String, Codable, Sendable { case prepared, stored, partial, restoring, restored }
public struct AIRecoveryRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let items: [AICleanupCandidate]
    public var state: AIRecoveryState
    public var restoredAt: Date?
    public var message: String
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    fileprivate var paths: [AIStoredPath]
    fileprivate var replacementGuards: [String: String]
    fileprivate var originalGuards: [String: String]
    fileprivate var tools: Set<AITool> { Set(items.map(\.tool)) }
}
private struct AIStoredPath: Codable {
    enum Operation: String, Codable { case move, databaseCopy, indexCopy, compactedOriginal, sqliteSidecar }
    let original: URL
    let stored: URL
    let operation: Operation
    var storedSignature: String?
    let gitCommonDirectory: URL?
    let initialIdentity: String?
    let relocationSignature: String?
    let allowsSymbolicLink: Bool
    var completed: Bool
}

/// Files are retained in a private recovery folder. Space is reclaimed only after the user removes that folder's contents.
/// The generic TrashStore admission remains unchanged: only the exact AI subpaths below are accepted here.
public actor AICleanupStore {
    public let recoveryRoot: URL
    private let home: URL
    private let activity: AIActivityProvider
    private var journal: URL { recoveryRoot.appendingPathComponent("history.json") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, recoveryRoot: URL? = nil,
                activity: @escaping AIActivityProvider = { AIActivity.runningTools() }) {
        self.home = AIPaths.normalized(home)
        self.recoveryRoot = AIPaths.normalized(recoveryRoot ?? home.appendingPathComponent("Library/Application Support/Orbit/AIRecovery"))
        self.activity = activity
    }

    public func history() throws -> [AIRecoveryRecord] {
        try prepareRoot()
        let lock = try AILock(recoveryRoot.appendingPathComponent("history.lock")); defer { lock.unlock() }
        return try load()
    }

    /// UI must show the exact selected paths, loss of local conversation access, and retained recovery size before calling.
    public func apply(_ selected: [AICleanupCandidate]) throws -> AIRecoveryRecord {
        guard !selected.isEmpty, Set(selected.map(\.id)).count == selected.count else { throw AICleanupError.unsafe("空或重复选择") }
        try prepareRoot()
        let lock = try AILock(recoveryRoot.appendingPathComponent("history.lock")); defer { lock.unlock() }
        var records = try load()
        let cursorSelected = selected.compactMap(\.cursorSession)
        var cursorCatalog: [AICursorSession]?
        if !cursorSelected.isEmpty {
            try ensureIdle([.cursor])
            let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            guard !(try AIPaths.databaseHasOpenFiles(database)) else { throw AICleanupError.busy(database.path) }
            cursorCatalog = try AIPaths.cursorSessions(home)
            try AIPaths.validateCursorSelection(cursorSelected, catalog: cursorCatalog ?? [])
        }
        var seen: [URL] = []
        for item in selected {
            try verify(item, cursorCatalog: cursorCatalog)
            for source in item.sources {
                guard !seen.contains(where: { AIPaths.within(source, $0) || AIPaths.within($0, source) }) else { throw AICleanupError.unsafe(source.path) }
                guard try AIPaths.stat(source, allowLink: item.kind == .tool).value.st_dev == AIPaths.stat(recoveryRoot).value.st_dev else { throw AICleanupError.unsafe("恢复目录与源文件必须位于同一磁盘") }
                seen.append(source)
            }
        }
        // A database cannot simultaneously be compacted and changed by session removal.
        let codexSessionDBs = Set(selected.compactMap(\.codexDatabase))
        let cursorSessionDBs = Set(selected.filter { $0.cursorSession != nil }.map(\.url))
        let sessionDBs = codexSessionDBs.union(cursorSessionDBs)
        guard !selected.contains(where: { $0.kind == .database && sessionDBs.contains($0.url) }) else {
            throw AICleanupError.unsafe("请分开执行会话清理和该数据库压缩")
        }
        var record = AIRecoveryRecord(id: UUID(), createdAt: Date(), items: selected, state: .prepared,
            restoredAt: nil, message: "准备处理；恢复副本仍占磁盘空间。", paths: [], replacementGuards: [:], originalGuards: [:])
        let directory = recoveryRoot.appendingPathComponent("items/" + record.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AIPaths.noSymlinks(directory)
        for item in selected {
            if item.kind == .database {
                for file in AIPaths.databaseFiles(item.url) {
                    record.paths.append(AIStoredPath(original: file, stored: directory.appendingPathComponent("part-\(record.paths.count)"),
                        operation: .compactedOriginal, storedSignature: nil, gitCommonDirectory: nil, initialIdentity: try AIPaths.identity(file), relocationSignature: try AIPaths.snapshot(file, ignoringRootChange: true).signature, allowsSymbolicLink: false, completed: false))
                }
            } else {
                for source in item.sources {
                    record.paths.append(AIStoredPath(original: source, stored: directory.appendingPathComponent("part-\(record.paths.count)"),
                        operation: .move, storedSignature: nil, gitCommonDirectory: item.gitCommonDirectory, initialIdentity: try AIPaths.identity(source), relocationSignature: try AIPaths.snapshot(source, ignoringRootChange: true, allowFinalLink: item.kind == .tool).signature, allowsSymbolicLink: item.kind == .tool, completed: false))
                }
            }
        }
        for database in sessionDBs.sorted(by: { $0.path < $1.path }) {
            record.paths.append(AIStoredPath(original: database, stored: directory.appendingPathComponent("db-\(record.paths.count).sqlite"),
                operation: .databaseCopy, storedSignature: nil, gitCommonDirectory: nil, initialIdentity: nil, relocationSignature: nil, allowsSymbolicLink: false, completed: false))
        }
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        if !codexSessionDBs.isEmpty, AIPaths.exists(index) {
            try AIPaths.noSymlinks(index)
            record.paths.append(AIStoredPath(original: index, stored: directory.appendingPathComponent("session-index.jsonl"),
                operation: .indexCopy, storedSignature: nil, gitCommonDirectory: nil, initialIdentity: nil, relocationSignature: nil, allowsSymbolicLink: false, completed: false))
        }
        records.append(record)
        func persist() throws {
            records[records.count - 1] = record; try save(records)
        }
        try persist()
        do {
            // Snapshot SQLite through its backup API, never by copying a possibly incomplete WAL main file.
            for position in record.paths.indices where record.paths[position].operation == .databaseCopy || record.paths[position].operation == .indexCopy {
                try ensureIdle(record.tools)
                let step = record.paths[position]
                record.originalGuards[step.original.path] = try AIPaths.contentHash(step.original)
                try persist()
                if step.operation == .databaseCopy {
                    try AIPaths.backupDatabase(step.original, to: step.stored)
                } else { try FileManager.default.copyItem(at: step.original, to: step.stored) }
                record.paths[position].storedSignature = try AIPaths.snapshot(step.stored, allowFinalLink: step.allowsSymbolicLink).signature
                record.paths[position].completed = true
                try persist()
            }
            for item in selected where item.kind == .database {
                try ensureIdle([item.tool]); try verify(item)
                let compact = directory.appendingPathComponent("compact-" + UUID().uuidString + ".sqlite")
                _ = try AIPaths.sqlite(item.url, "VACUUM INTO \(AIPaths.sqlString(compact.path));")
                guard try AIPaths.sqlite(compact, "PRAGMA quick_check;").trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw AICleanupError.command("压缩后的数据库未通过检查") }
                try ensureIdle([item.tool]); try verify(item)
                record.originalGuards[item.url.path] = try AIPaths.contentHash(item.url)
                record.replacementGuards[item.url.path] = try AIPaths.contentHash(compact)
                try persist()
                for position in record.paths.indices where record.paths[position].operation == .compactedOriginal && AIPaths.databaseFiles(item.url, includeMissing: true).contains(record.paths[position].original) {
                    try moveStep(&record, position: position); try persist()
                }
                try FileManager.default.moveItem(at: compact, to: item.url)
                try persist()
            }
            for position in record.paths.indices where record.paths[position].operation == .move {
                try ensureIdle(record.tools)
                let source = record.paths[position].original
                guard let item = selected.first(where: { $0.sources.contains(source) }) else { throw AICleanupError.unsafe(source.path) }
                if let signature = item.signatures[source.path], try AIPaths.snapshot(source, allowFinalLink: item.kind == .tool).signature != signature { throw AICleanupError.changed(source.path) }
                if item.kind == .worktree { _ = try AIPaths.safeWorktree(source, now: Date()) }
                if item.kind == .orphanedVisualization {
                    guard let id = item.orphanedThreadID, try !AIPaths.codexReferences(home).references(id: id, image: source) else { throw AICleanupError.changed(source.path) }
                }
                if item.kind == .model {
                    if source == item.url { try verifyModel(item) }
                    else if try AIPaths.ollamaManifests(home).contains(where: { $0.blobs.contains(source) }) { throw AICleanupError.changed(source.path) }
                }
                try moveStep(&record, position: position); try persist()
            }
            for database in sessionDBs {
                let cursorItems = selected.filter { $0.cursorSession != nil && $0.url == database }
                let tool: AITool = cursorItems.isEmpty ? .codex : .cursor
                try ensureIdle([tool])
                let mutation: String
                if cursorItems.isEmpty {
                    let ids = selected.filter { $0.codexDatabase == database }.compactMap(\.threadID)
                    for item in selected where item.codexDatabase == database {
                        guard let id = item.threadID, try AIPaths.codexHasThread(database, id: id, path: item.url.path) else { throw AICleanupError.changed(database.path) }
                    }
                    let clauses = ids.map(AIPaths.sqlString).joined(separator: ",")
                    mutation = "DELETE FROM threads WHERE id IN (\(clauses));"
                } else {
                    let catalog = try AIPaths.cursorSessions(home)
                    let plans = cursorItems.compactMap(\.cursorSession)
                    try AIPaths.validateCursorSelection(plans, catalog: catalog)
                    mutation = try AIPaths.cursorDeleteSQL(plans)
                }
                guard let backup = record.paths.first(where: { $0.operation == .databaseCopy && $0.original == database }) else { throw AICleanupError.corruptHistory }
                let staged = directory.appendingPathComponent("updated-" + UUID().uuidString + ".sqlite")
                try FileManager.default.copyItem(at: backup.stored, to: staged)
                _ = try AIPaths.sqlite(staged, "PRAGMA foreign_keys=ON; BEGIN IMMEDIATE; " + mutation + " COMMIT; VACUUM; PRAGMA journal_mode=DELETE;", readOnly: false)
                record.replacementGuards[database.path] = try AIPaths.contentHash(staged)
                try persist()
                try ensureIdle([tool])
                guard try AIPaths.contentHash(database) == record.originalGuards[database.path], !(try AIPaths.databaseHasOpenFiles(database)) else { throw AICleanupError.changed(database.path) }
                for sidecar in AIPaths.databaseFiles(database).filter({ $0 != database }) {
                    record.paths.append(AIStoredPath(original: sidecar, stored: directory.appendingPathComponent("sidecar-\(record.paths.count)"), operation: .sqliteSidecar,
                        storedSignature: nil, gitCommonDirectory: nil, initialIdentity: try AIPaths.identity(sidecar), relocationSignature: try AIPaths.snapshot(sidecar, ignoringRootChange: true).signature, allowsSymbolicLink: false, completed: false))
                    try persist()
                    try moveStep(&record, position: record.paths.count - 1); try persist()
                }
                try AIPaths.atomicReplace(staged, destination: database)
                try persist()
            }
            if !codexSessionDBs.isEmpty, AIPaths.exists(index) {
                let ids = Set(selected.compactMap(\.threadID))
                let data = try Data(contentsOf: index)
                guard data.count <= 32 * 1024 * 1024 else { throw AICleanupError.budget }
                var output = Data()
                for line in data.split(separator: 10) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let id = object["id"] as? String else { throw AICleanupError.command("会话索引包含未知记录，保留恢复副本并停止。") }
                    if !ids.contains(id) { output.append(contentsOf: line); output.append(10) }
                }
                let staged = directory.appendingPathComponent("updated-index.jsonl")
                try output.write(to: staged, options: .atomic)
                record.replacementGuards[index.path] = try AIPaths.contentHash(staged)
                try persist()
                try ensureIdle([.codex])
                guard try AIPaths.contentHash(index) == record.originalGuards[index.path] else { throw AICleanupError.changed(index.path) }
                try AIPaths.atomicReplace(staged, destination: index)
                try persist()
            }
            record.state = .stored; record.message = "已移入恢复目录；副本仍占磁盘空间，可在 AI 恢复记录中还原。"
            try persist(); return record
        } catch {
            record.state = .partial; record.message = error.localizedDescription + " 已完成的步骤保留在恢复记录中。"
            try persist(); return record
        }
    }

    public func restore(_ id: UUID) throws {
        try prepareRoot()
        let lock = try AILock(recoveryRoot.appendingPathComponent("history.lock")); defer { lock.unlock() }
        var records = try load()
        guard let recordIndex = records.firstIndex(where: { $0.id == id }), records[recordIndex].state != .restored else { throw AICleanupError.unsafe("恢复记录") }
        var record = records[recordIndex]
        try ensureIdle(record.tools)
        for item in record.items where item.kind == .model {
            for (path, signature) in item.dependencies {
                let dependency = URL(fileURLWithPath: path)
                guard AIPaths.exists(dependency), try AIPaths.snapshot(dependency, ignoringRootChange: true).signature == signature else {
                    throw AICleanupError.conflict("共享模型权重缺失或改变，请先恢复包含它的记录：" + path)
                }
            }
        }
        // Preflight all steps before restoring any: never overwrite new conversations or a replacement file.
        for step in record.paths where step.completed {
            guard AIPaths.within(step.stored, recoveryRoot), let signature = step.storedSignature,
                  try AIPaths.snapshot(step.stored, allowFinalLink: step.allowsSymbolicLink).signature == signature else { throw AICleanupError.changed(step.stored.path) }
            try AIPaths.noSymlinks(step.original.deletingLastPathComponent())
            switch step.operation {
            case .move:
                if AIPaths.exists(step.original) { throw AICleanupError.conflict(step.original.path) }
            case .databaseCopy, .indexCopy, .compactedOriginal:
                let main = step.operation == .compactedOriginal ? record.items.first(where: { $0.kind == .database && AIPaths.databaseFiles($0.url, includeMissing: true).contains(step.original) })?.url : step.original
                if let main, AIPaths.exists(main) {
                    let signature = try AIPaths.contentHash(main)
                    guard signature == record.replacementGuards[main.path] || signature == record.originalGuards[main.path] else { throw AICleanupError.conflict(main.path) }
                    if step.operation != .indexCopy, try AIPaths.databaseHasOpenFiles(main) { throw AICleanupError.busy(main.path) }
                }
            case .sqliteSidecar: break // A consistent SQLite backup already includes these pages; never replay old WAL over it.
            }
        }
        record.state = .restoring; records[recordIndex] = record; try save(records)
        for position in record.paths.indices.reversed() where record.paths[position].completed {
            try ensureIdle(record.tools)
            let step = record.paths[position]
            switch step.operation {
            case .move:
                try FileManager.default.createDirectory(at: step.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let common = step.gitCommonDirectory {
                    _ = try AIPaths.git(common, ["worktree", "move", "--", step.stored.path, step.original.path], bare: true)
                    _ = try AIPaths.git(step.original, ["worktree", "repair", "--", step.original.path])
                } else { try FileManager.default.moveItem(at: step.stored, to: step.original) }
            case .databaseCopy, .indexCopy:
                let displaced = step.stored.deletingLastPathComponent().appendingPathComponent("replaced-" + UUID().uuidString)
                if AIPaths.exists(step.original) { try FileManager.default.moveItem(at: step.original, to: displaced) }
                if step.operation == .databaseCopy {
                    for sidecar in AIPaths.databaseFiles(step.original).filter({ $0 != step.original }) {
                        try FileManager.default.moveItem(at: sidecar, to: displaced.appendingPathExtension(sidecar.lastPathComponent))
                    }
                }
                try FileManager.default.copyItem(at: step.stored, to: step.original)
            case .sqliteSidecar: break
            case .compactedOriginal:
                if AIPaths.exists(step.original) {
                    let displaced = step.stored.deletingLastPathComponent().appendingPathComponent("replaced-" + UUID().uuidString)
                    try FileManager.default.moveItem(at: step.original, to: displaced)
                }
                try FileManager.default.moveItem(at: step.stored, to: step.original)
            }
            record.paths[position].completed = false
            records[recordIndex] = record; try save(records)
        }
        record.state = .restored; record.restoredAt = Date(); record.message = "已恢复原位置。"
        records[recordIndex] = record; try save(records)
    }

    /// Reusable by maintenance callers for one of the exact databases recognized by the AI policy.
    public func compactDatabase(at url: URL, tool: AITool) throws -> AIRecoveryRecord {
        guard try AIPaths.databases(home).contains(where: { $0.0 == tool && $0.1 == url }) else { throw AICleanupError.unsafe(url.path) }
        let stamp = try AIPaths.snapshot(url)
        let candidate = AICleanupCandidate(tool: tool, kind: .database, url: url, title: url.lastPathComponent,
            detail: "保留所有记录，压缩空闲页。", bytes: stamp.bytes, modifiedAt: stamp.latest,
            sources: [url], signatures: [url.path: stamp.signature], dependencies: [:], codexDatabase: nil, threadID: nil, gitCommonDirectory: nil, cursorSession: nil, orphanedThreadID: nil)
        return try apply([candidate])
    }

    private func verify(_ item: AICleanupCandidate, cursorCatalog: [AICursorSession]? = nil) throws {
        try ensureIdle([item.tool])
        guard !item.sources.isEmpty || item.kind == .databaseSession else { throw AICleanupError.unsafe(item.url.path) }
        if item.kind == .databaseSession {
            guard item.tool == .cursor else { throw AICleanupError.unsafe(item.url.path) }
            try AIPaths.admit(item.url, kind: .databaseSession, home: home)
            guard let plan = item.cursorSession, let signature = item.signatures[item.url.path],
                  try AIPaths.snapshot(item.url).signature == signature,
                  (try cursorCatalog ?? AIPaths.cursorSessions(home)).contains(plan) else { throw AICleanupError.changed(item.url.path) }
        }
        if item.kind == .orphanedVisualization {
            guard item.tool == .codex, let id = item.orphanedThreadID, AIPaths.visualizationThreadID(item.url, home: home) == id,
                  try !AIPaths.codexReferences(home).references(id: id, image: item.url) else { throw AICleanupError.changed(item.url.path) }
        }
        for source in item.sources {
            try AIPaths.admit(source, kind: item.kind, home: home)
            guard let signature = item.signatures[source.path], try AIPaths.snapshot(source, allowFinalLink: item.kind == .tool).signature == signature else { throw AICleanupError.changed(source.path) }
        }
        if item.kind == .worktree {
            guard try AIPaths.safeWorktree(item.url, now: Date()) == item.gitCommonDirectory else { throw AICleanupError.changed(item.url.path) }
        }
        if item.kind == .oldVersion {
            guard let location = AIPaths.cliVersionRoots.first(where: { home.appendingPathComponent($0.root).path == item.url.deletingLastPathComponent().path }),
                  location.tool == item.tool else { throw AICleanupError.unsafe(item.url.path) }
            let versions = try AIPaths.children(home.appendingPathComponent(location.root)).filter {
                guard AIPaths.versionComponents($0.lastPathComponent, tool: location.tool) != nil,
                      let metadata = try? AIPaths.stat($0) else { return false }
                return location.tool != .cursor || metadata.isDirectory
            }
            if try AIPaths.preservedVersions(versions, location: location, home: home).contains(item.url.path) { throw AICleanupError.changed(item.url.path) }
        }
        if item.kind == .model { try verifyModel(item) }
        if let database = item.codexDatabase, let id = item.threadID {
            guard database == (try AIPaths.codexDatabase(home)), try AIPaths.codexHasThread(database, id: id, path: item.url.path), !(try AIPaths.databaseHasOpenFiles(database)) else { throw AICleanupError.busy(database.path) }
        }
        if item.kind == .database, try AIPaths.databaseHasOpenFiles(item.url) { throw AICleanupError.busy(item.url.path) }
    }
    private func verifyModel(_ item: AICleanupCandidate) throws {
        let manifests = try AIPaths.ollamaManifests(home)
        guard let manifest = manifests.first(where: { $0.url == item.url }) else { throw AICleanupError.changed(item.url.path) }
        for blob in item.sources where blob != item.url {
            guard manifest.blobs.contains(blob), !manifests.contains(where: { $0.url != item.url && $0.blobs.contains(blob) }) else { throw AICleanupError.changed(blob.path) }
        }
    }
    private func ensureIdle(_ tools: Set<AITool>) throws {
        if Task<Never, Never>.isCancelled { throw AICleanupError.cancelled }
        let busy = activity().intersection(tools)
        if !busy.isEmpty { throw AICleanupError.busy(busy.map(\.title).sorted().joined(separator: "、")) }
    }
    private func moveStep(_ record: inout AIRecoveryRecord, position: Int) throws {
        let step = record.paths[position]
        try AIPaths.noSymlinks(step.original, allowFinalLink: step.allowsSymbolicLink)
        if let common = step.gitCommonDirectory {
            _ = try AIPaths.git(common, ["worktree", "move", "--", step.original.path, step.stored.path], bare: true)
            _ = try AIPaths.git(step.stored, ["worktree", "repair", "--", step.stored.path])
        } else {
            guard !AIPaths.exists(step.stored), rename(step.original.path, step.stored.path) == 0 else { throw AICleanupError.changed(step.original.path) }
        }
        record.paths[position].storedSignature = try AIPaths.snapshot(step.stored, allowFinalLink: step.allowsSymbolicLink).signature
        record.paths[position].completed = true
    }
    private func prepareRoot() throws {
        try AIPaths.noSymlinks(recoveryRoot, allowMissing: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try AIPaths.stat(recoveryRoot).owner == getuid() else { throw AICleanupError.unsafe(recoveryRoot.path) }
    }
    private func load() throws -> [AIRecoveryRecord] {
        guard AIPaths.exists(journal) else { return [] }
        try AIPaths.noSymlinks(journal)
        guard let data = try? Data(contentsOf: journal), data.count <= 20 * 1024 * 1024,
              var records = try? JSONDecoder().decode([AIRecoveryRecord].self, from: data) else { throw AICleanupError.corruptHistory }
        var reconciled = false
        for index in records.indices where records[index].state != .restored {
            let restoring = records[index].state == .restoring
            for stepIndex in records[index].paths.indices {
                var step = records[index].paths[stepIndex]
                guard AIPaths.within(step.stored, recoveryRoot.appendingPathComponent("items/" + records[index].id.uuidString)) else { throw AICleanupError.corruptHistory }
                if !step.completed, [.move, .compactedOriginal, .sqliteSidecar].contains(step.operation),
                   AIPaths.exists(step.stored), try AIPaths.identity(step.stored) == step.initialIdentity {
                    guard try AIPaths.snapshot(step.stored, ignoringRootChange: true, allowFinalLink: step.allowsSymbolicLink).signature == step.relocationSignature else { throw AICleanupError.changed(step.stored.path) }
                    step.completed = true; step.storedSignature = try AIPaths.snapshot(step.stored, allowFinalLink: step.allowsSymbolicLink).signature
                    records[index].state = restoring ? .restoring : .partial; reconciled = true
                } else if restoring, step.completed, [.databaseCopy, .indexCopy].contains(step.operation),
                          AIPaths.exists(step.original), AIPaths.exists(step.stored), try AIPaths.contentHash(step.original) == AIPaths.contentHash(step.stored) {
                    step.completed = false; reconciled = true
                } else if restoring, step.completed, step.operation == .move || step.operation == .compactedOriginal,
                          !AIPaths.exists(step.stored), AIPaths.exists(step.original), try AIPaths.identity(step.original) == step.initialIdentity {
                    guard try AIPaths.snapshot(step.original, ignoringRootChange: true, allowFinalLink: step.allowsSymbolicLink).signature == step.relocationSignature else { throw AICleanupError.changed(step.original.path) }
                    step.completed = false; reconciled = true
                }
                records[index].paths[stepIndex] = step
            }
        }
        if reconciled { try save(records) }
        return records
    }
    private func save(_ records: [AIRecoveryRecord]) throws {
        try JSONEncoder().encode(records).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let fd = open(journal.path, O_RDONLY | O_NOFOLLOW); if fd >= 0 { fsync(fd); close(fd) }
        let directory = open(recoveryRoot.path, O_RDONLY); if directory >= 0 { fsync(directory); close(directory) }
    }
}

private final class AIBudget {
    private let maximum: Int
    private let deadline: TimeInterval
    var count = 0
    init(maximum: Int, seconds: TimeInterval) { self.maximum = maximum; deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds) }
    func check() throws {
        if Task<Never, Never>.isCancelled { throw AICleanupError.cancelled }
        if count >= maximum || ProcessInfo.processInfo.systemUptime >= deadline { throw AICleanupError.budget }
    }
    func visit() throws { try check(); count += 1 }
}
private struct AIFileStat {
    let value: stat
    var isDirectory: Bool { value.st_mode & S_IFMT == S_IFDIR }
    var owner: uid_t { value.st_uid }
    var modified: Date { Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9) }
    var signature: String { stableSignature + ":\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)" }
    var stableSignature: String { "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_nlink):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)" }
}
private struct AISnapshot { let signature: String; let bytes: Int64; let latest: Date }
private struct AIManifest { let url: URL; let blobs: [URL] }
private struct AICursorSession: Codable, Hashable, Sendable {
    let composerID: String
    let rootVersion: Int
    let updatedAtMilliseconds: Int64
    let bytes: Int64
    let rowCount: Int
    var referencedIDs: Set<String>
    var eligibility: String?
    let schemaSignature: String
}
private struct AICodexReferences {
    let ids: Set<String>
    let database: URL
    func references(id: String, image: URL) throws -> Bool {
        if ids.contains(id.lowercased()) { return true }
        // Search attachment metadata inside SQLite; no payload or URL value is returned to the scanner.
        let clauses = [id, image.path, image.absoluteString].flatMap { value in
            ["instr(identity_key,\(AIPaths.sqlString(value)))>0", "instr(payload,\(AIPaths.sqlString(value)))>0"]
        }.joined(separator: " OR ")
        return try AIPaths.sqlite(database, "SELECT count(*) FROM thread_attachments WHERE " + clauses + ";").trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }
}
private struct AICLIVersionRoot {
    let tool: AITool
    let root: String
    let entry: String
}
private enum AIPaths {
    static let protectedNames: Set<String> = ["memory", "memories", "plans", "skills", "auth.json", "credentials", ".credentials.json", "settings.json", "config.toml", "agents.md", "claude.md", "system.md", "append_system.md"]
    static let cacheRoots: [(AITool, String)] = [
        (.claude, ".claude/cache"), (.claude, ".claude/debug"), (.claude, ".claude/downloads"),
        (.codex, ".codex/log"), (.codex, ".cache/codex"), (.claude, ".cache/claude-cli-nodejs"),
        (.codex, "Library/Caches/com.openai.codex"), (.claude, "Library/Caches/com.anthropic.claudefordesktop"),
        (.cursor, "Library/Application Support/Cursor/Cache"), (.cursor, "Library/Application Support/Cursor/Code Cache"),
        (.cursor, "Library/Application Support/Cursor/GPUCache")]
    static let sessionRoots: [(AITool, String, AICleanupKind)] = [(.codex, ".codex/sessions", .session), (.codex, ".codex/archived_sessions", .session),
        (.claude, ".claude/projects", .session), (.cursor, ".cursor/projects", .archive), (.pi, ".pi/agent/sessions", .session)]
    static let toolEntries: [(AITool, String)] = [(.claude, "claude"), (.codex, "codex"), (.cursor, "cursor-agent"), (.pi, "pi"), (.ollama, "ollama")]
    static let cliVersionRoots: [AICLIVersionRoot] = [
        AICLIVersionRoot(tool: .claude, root: ".local/share/claude/versions", entry: ".local/bin/claude"),
        AICLIVersionRoot(tool: .cursor,
            root: "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions",
            entry: "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent")]
    static let worktreeRoots: [(AITool, String)] = [(.codex, ".codex/worktrees"), (.claude, ".claude/worktrees"), (.cursor, ".cursor/worktrees")]
    static func normalized(_ url: URL) -> URL {
        var parts: [String] = []
        for part in url.pathComponents where part != "/" && part != "." {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: false)
    }
    static func within(_ url: URL, _ root: URL) -> Bool { url.path == root.path || url.path.hasPrefix(root.path + "/") }
    static func exists(_ url: URL) -> Bool { var st = Darwin.stat(); return lstat(url.path, &st) == 0 }
    static func stat(_ url: URL, allowLink: Bool = false) throws -> AIFileStat {
        var value = Darwin.stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
        guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR || (allowLink && value.st_mode & S_IFMT == S_IFLNK) else { throw AICleanupError.unsafe(url.path) }
        if value.st_mode & S_IFMT == S_IFREG && value.st_nlink != 1 { throw AICleanupError.unsafe(url.path) }
        return AIFileStat(value: value)
    }
    static func noSymlinks(_ url: URL, allowMissing: Bool = false, allowFinalLink: Bool = false) throws {
        guard normalized(url).path == url.path else { throw AICleanupError.unsafe(url.path) }
        var path = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            path.appendPathComponent(component)
            var st = Darwin.stat()
            if lstat(path.path, &st) != 0 {
                if allowMissing && errno == ENOENT { return }
                throw AICleanupError.changed(path.path)
            }
            if st.st_mode & S_IFMT == S_IFLNK && !(allowFinalLink && path == url) { throw AICleanupError.unsafe(path.path) }
        }
    }
    static func identity(_ url: URL) throws -> String {
        let value = try stat(url, allowLink: true).value
        return "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_uid)"
    }
    static func contentHash(_ url: URL) throws -> String {
        try noSymlinks(url)
        let before = try stat(url)
        guard !before.isDirectory, before.value.st_size <= 2 * 1024 * 1024 * 1024 else { throw AICleanupError.budget }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let header = try file.read(upToCount: 16) ?? Data()
        if header == Data("SQLite format 3\0".utf8) {
            // Hash logical rows and schema: VACUUM and restoring a consistent snapshot may change on-disk layout.
            let digest = try sqlite(url, ".sha3sum --schema --sha3-256").trimmingCharacters(in: .whitespacesAndNewlines)
            let version = try sqlite(url, "PRAGMA user_version; PRAGMA application_id;").trimmingCharacters(in: .whitespacesAndNewlines)
            guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  try stat(url).signature == before.signature else { throw AICleanupError.changed(url.path) }
            return "sqlite:" + digest + ":" + version
        }
        try file.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        guard try stat(url).signature == before.signature else { throw AICleanupError.changed(url.path) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func atomicReplace(_ source: URL, destination: URL) throws {
        try noSymlinks(source); try noSymlinks(destination.deletingLastPathComponent())
        guard rename(source.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = open(destination.path, O_RDONLY | O_NOFOLLOW); if file >= 0 { fsync(file); close(file) }
        let parent = open(destination.deletingLastPathComponent().path, O_RDONLY); if parent >= 0 { fsync(parent); close(parent) }
    }
    static func children(_ root: URL) throws -> [URL] {
        try noSymlinks(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }
    static func snapshot(_ url: URL, budget: AIBudget? = nil, ignoringRootChange: Bool = false, allowFinalLink: Bool = false) throws -> AISnapshot {
        try noSymlinks(url, allowFinalLink: allowFinalLink)
        let limit = budget ?? AIBudget(maximum: 100_000, seconds: 30)
        let root = try stat(url, allowLink: allowFinalLink)
        var list: [(String, AIFileStat)] = [("", root)]
        var bytes = root.isDirectory || root.value.st_mode & S_IFMT == S_IFLNK ? 0 : max(0, root.value.st_size)
        var latest = root.modified
        if root.isDirectory {
            var readError: Error?
            guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in readError = error; return false }) else { throw AICleanupError.unsafe(url.path) }
            for case let child as URL in iterator {
                try limit.visit()
                let value = try stat(child)
                let name = child.lastPathComponent.lowercased()
                if protectedNames.contains(name), !insideApplication(child, root: url) { throw AICleanupError.unsafe(child.path) }
                list.append((String(child.path.dropFirst(url.path.count)), value))
                if !value.isDirectory { bytes += max(0, value.value.st_size) }
                latest = max(latest, value.modified)
            }
            if let readError { throw readError }
        } else { try limit.visit() }
        var hasher = SHA256()
        for (path, value) in list.sorted(by: { $0.0 < $1.0 }) {
            let stamp = ignoringRootChange && path.isEmpty ? value.stableSignature : value.signature
            hasher.update(data: Data((path + "\0" + stamp + "\n").utf8))
        }
        return AISnapshot(signature: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes, latest: latest)
    }
    /// Names such as skills inside a downloaded .app (an update staged in a cache) are app resources, not user data.
    static func insideApplication(_ url: URL, root: URL) -> Bool {
        url.path.dropFirst(root.path.count).split(separator: "/").dropLast().contains { $0.lowercased().hasSuffix(".app") }
    }
    static func admit(_ url: URL, kind: AICleanupKind, home: URL) throws {
        try noSymlinks(url, allowFinalLink: kind == .tool)
        guard normalized(home).path == home.path, within(url, home) else { throw AICleanupError.unsafe(url.path) }
        let relative = String(url.path.dropFirst(home.path.count + 1))
        if relative.split(separator: "/").contains(where: { protectedNames.contains($0.lowercased()) }) { throw AICleanupError.unsafe(url.path) }
        let okay: Bool
        switch kind {
        case .cache:
            // FileManager may return the disk's spelling (cache) for a configured Cache root.
            // Match this case alias by directory identity rather than loosening path matching.
            let parentIdentity = try identity(url.deletingLastPathComponent())
            okay = cacheRoots.contains {
                relative.hasPrefix($0.1 + "/") || (try? identity(home.appendingPathComponent($0.1))) == parentIdentity
            }
        case .oldVersion: okay = cliVersionRoots.contains {
            url.deletingLastPathComponent().path == home.appendingPathComponent($0.root).path && versionComponents(url.lastPathComponent, tool: $0.tool) != nil
                && ($0.tool != .cursor || (try? stat(url).isDirectory) == true)
        }
        case .session, .archive: okay = sessionRoots.contains { tool, path, type in type == kind && isSession(url, root: home.appendingPathComponent(path), tool: tool) }
        case .worktree: okay = worktreeRoots.contains { within(url, home.appendingPathComponent($0.1)) && url != home.appendingPathComponent($0.1) }
        case .model: okay = relative.hasPrefix(".ollama/models/manifests/") || (url.deletingLastPathComponent() == home.appendingPathComponent(".ollama/models/blobs") && digestFile(url.lastPathComponent))
        case .database: okay = (try databases(home)).contains { $0.1 == url }
        case .tool: okay = toolEntries.contains { url == home.appendingPathComponent(".local/bin/" + $0.1) }
        case .databaseSession: okay = url == home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        case .orphanedVisualization: okay = try visualizationThreadID(url, home: home) != nil && !stat(url).isDirectory
        }
        guard okay else { throw AICleanupError.unsafe(url.path) }
        guard try stat(url, allowLink: kind == .tool).owner == getuid() else { throw AICleanupError.unsafe(url.path) }
    }
    static func isSession(_ url: URL, root: URL, tool: AITool) -> Bool {
        guard within(url, root), url != root else { return false }
        let parts = String(url.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        let file = url.lastPathComponent
        switch tool {
        case .codex: return file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") && codexThreadID(url) != nil && ((parts.count == 1 && root.lastPathComponent == "archived_sessions") || (parts.count == 4 && parts.dropLast().allSatisfy { $0.allSatisfy(\.isNumber) }))
        case .claude: return parts.count == 2 && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil && url.pathExtension == "jsonl"
        case .cursor: return parts.count >= 3 && parts.count <= 4 && parts[1] == "agent-transcripts" && ["txt", "jsonl"].contains(url.pathExtension) && (UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil)
        case .pi: return parts.count == 2 && url.pathExtension == "jsonl" && file.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", options: .regularExpression) != nil
        case .ollama: return false
        }
    }
    static func codexThreadID(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else { return nil }
        let id = String(name.suffix(36)); return UUID(uuidString: id) == nil ? nil : id
    }
    static func version(_ string: String) -> [Int]? {
        let values = string.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let ints = values.compactMap { Int($0) }; return ints.count == 3 ? ints : nil
    }
    static func versionComponents(_ name: String, tool: AITool) -> [Int]? {
        if tool == .claude { return version(name) }
        guard tool == .cursor, name.range(of: "^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-[0-9a-fA-F]{7,40}$", options: .regularExpression) != nil,
              let datePart = name.split(separator: "-").first, let values = version(String(datePart)) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == values[0], actual.month == values[1], actual.day == values[2] else { return nil }
        return values
    }
    static func preservedVersions(_ files: [URL], location: AICLIVersionRoot, home: URL) throws -> Set<String> {
        let root = home.appendingPathComponent(location.root)
        let latest = files.compactMap { versionComponents($0.lastPathComponent, tool: location.tool) }
            .max { $0.lexicographicallyPrecedes($1) }
        // Build hashes have no chronological order; keep every build on the latest release date.
        var result = Set(files.filter { versionComponents($0.lastPathComponent, tool: location.tool) == latest }.map(\.path))
        var entries = [(home.appendingPathComponent(location.entry), true), (root.appendingPathComponent("current"), true), (root.appendingPathComponent("latest"), true)]
        if location.tool == .cursor { entries.append((home.appendingPathComponent(".local/bin/cursor-agent"), false)) }
        for (entry, mustBelong) in entries where exists(entry) {
            try noSymlinks(entry, allowFinalLink: true)
            guard try stat(entry, allowLink: true).value.st_mode & S_IFMT == S_IFLNK else {
                if !mustBelong { continue }
                throw AICleanupError.unsafe("无法核对当前版本入口：" + entry.path)
            }
            guard let resolved = realpath(entry.path, nil) else {
                if !mustBelong { continue }
                throw AICleanupError.unsafe("无法核对当前版本入口：" + entry.path)
            }
            let target = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
            if !mustBelong && !within(target, root) { continue }
            guard within(target, root), target.path != root.path,
                  let name = target.path.dropFirst(root.path.count + 1).split(separator: "/").first,
                  versionComponents(String(name), tool: location.tool) != nil else { throw AICleanupError.unsafe("版本入口目标不在已确认的版本目录中：" + entry.path) }
            result.insert(root.appendingPathComponent(String(name)).path)
        }
        return result
    }
    static func codexDatabase(_ home: URL) throws -> URL? {
        let root = home.appendingPathComponent(".codex")
        guard exists(root) else { return nil }
        return try children(root).filter { $0.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression) != nil }
            .max { Int($0.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0 < Int($1.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0 }
    }
    static func databases(_ home: URL) throws -> [(AITool, URL)] {
        var result: [(AITool, URL)] = [(.cursor, home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"))]
        if let db = try codexDatabase(home) { result.append((.codex, db)) }
        return result
    }
    static func sqlString(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "''") + "'" }
    static func sqlite(_ file: URL, _ sql: String, readOnly: Bool = true) throws -> String {
        try noSymlinks(file)
        return try AICommand.run("/usr/bin/sqlite3", ["-batch", "-bail"] + (readOnly ? ["-readonly"] : []) + [file.path, sql], timeout: 30)
    }
    static func backupDatabase(_ file: URL, to destination: URL) throws {
        guard !exists(destination) else { throw AICleanupError.conflict(destination.path) }
        // VACUUM INTO is a consistent SQLite snapshot and does not change the source database.
        _ = try sqlite(file, "VACUUM INTO \(sqlString(destination.path));")
        guard try sqlite(destination, "PRAGMA quick_check;").trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw AICleanupError.command("数据库恢复副本检查失败") }
    }
    static func codexHasThread(_ database: URL, id: String, path: String) throws -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        let result = try sqlite(database, "SELECT count(*) FROM threads WHERE id=\(sqlString(id)) AND rollout_path=\(sqlString(path));")
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
    static func databaseFiles(_ url: URL, includeMissing: Bool = false) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")].filter { includeMissing || exists($0) }
    }
    static func databaseHasOpenFiles(_ url: URL) throws -> Bool {
        let result = try AICommand.run("/usr/sbin/lsof", ["-t", "--"] + databaseFiles(url).map(\.path), timeout: 5, acceptedExits: [0, 1])
        return !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func git(_ root: URL, _ arguments: [String], bare: Bool = false) throws -> String {
        let prefix = bare ? ["--git-dir", root.path] : ["-C", root.path]
        return try AICommand.run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + prefix + arguments, timeout: 10)
    }
    static func safeWorktree(_ root: URL, now: Date) throws -> URL {
        try noSymlinks(root)
        guard try stat(root.appendingPathComponent(".git")).value.st_mode & S_IFMT == S_IFREG else { throw AICleanupError.unsafe("只处理链接工作树") }
        if exists(root.appendingPathComponent(".codex-worktree-name")) || exists(root.appendingPathComponent(".t3")) { throw AICleanupError.unsafe("仍由 Agent 应用管理的工作树") }
        let state = try git(root, ["status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching"])
        guard state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AICleanupError.unsafe("有未提交改动、新文件或忽略的本地文件") }
        guard try git(root, ["submodule", "status"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AICleanupError.unsafe("含有子模块") }
        guard !(try git(root, ["for-each-ref", "--contains=HEAD", "--format=%(refname)", "refs/remotes/"])).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AICleanupError.unsafe("提交尚未保存在远端引用中") }
        let listing = try git(root, ["worktree", "list", "--porcelain"])
        if listing.components(separatedBy: "\n\n").contains(where: { $0.hasPrefix("worktree " + root.path + "\n") && $0.split(separator: "\n").contains(where: { $0.hasPrefix("locked") }) }) { throw AICleanupError.unsafe("工作树已锁定") }
        let stamp = try snapshot(root)
        guard stamp.latest <= now.addingTimeInterval(-86400) else { throw AICleanupError.unsafe("24 小时内有文件活动") }
        let path = try git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let common = URL(fileURLWithPath: path)
        try noSymlinks(common)
        guard try stat(common).owner == getuid() else { throw AICleanupError.unsafe(common.path) }
        return common
    }
    static func sqliteRows(_ file: URL, _ sql: String) throws -> [[String: Any]] {
        try noSymlinks(file)
        let output = try AICommand.run("/usr/bin/sqlite3", ["-readonly", "-json", "-batch", "-bail", file.path, sql], timeout: 15)
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let data = output.data(using: .utf8), let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw AICleanupError.command("数据库返回未知结构，已保留。") }
        return rows
    }
    static func schemaColumns(_ database: URL, table: String) throws -> [String] {
        guard ["ItemTable", "cursorDiskKV", "composerHeaders", "threads", "thread_attachments", "local_thread_catalog", "live_visualization_suggestions", "thread_timeline_ledger", "local_thread_catalog_scan_entries"].contains(table) else { throw AICleanupError.unsafe(table) }
        return try sqliteRows(database, "PRAGMA table_info(\(table));").compactMap { $0["name"] as? String }
    }
    static let cursorExactPrefixes = ["composerData:", "composerRootWriterDiagnostic:", "localAgentMailboxCursor:", "agentKv:checkpoint:"]
    static let cursorOwnedPrefixes = ["bubbleId:", "checkpointId:", "codeBlockDiff:", "codeBlockPartialInlineDiffFates:", "composerConvHeaders:", "ofsContent:", "agentKv:bubbleCheckpoint:"]
    static func cursorKeyPredicate(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw AICleanupError.unsafe("无法识别 Cursor 会话标识") }
        let exact = cursorExactPrefixes.map { "key=" + sqlString($0 + id) }
        let namespaces = cursorOwnedPrefixes.map { "key GLOB " + sqlString($0 + id + ":*") }
        return "(" + (exact + namespaces).joined(separator: " OR ") + ")"
    }
    static func cursorSessions(_ home: URL, budget: AIBudget? = nil) throws -> [AICursorSession] {
        let limit = budget ?? AIBudget(maximum: 100_000, seconds: 30)
        let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try noSymlinks(database)
        guard try schemaColumns(database, table: "ItemTable") == ["key", "value"],
              try schemaColumns(database, table: "cursorDiskKV") == ["key", "value"],
              try schemaColumns(database, table: "composerHeaders") == ["composerId", "workspaceId", "createdAt", "lastUpdatedAt", "isArchived", "isSubagent", "recency", "checkpointAt", "value", "subagentTypeName"] else {
            throw AICleanupError.command("Cursor 会话数据库结构尚未识别，全部保留。")
        }
        let schema = try sqliteRows(database, "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*' ORDER BY type,name;")
        let tables = Set(schema.filter { $0["type"] as? String == "table" }.compactMap { $0["name"] as? String })
        guard tables == ["ItemTable", "cursorDiskKV", "composerHeaders"], !schema.contains(where: { $0["type"] as? String == "trigger" }) else { throw AICleanupError.command("Cursor 有未知会话表或触发器，全部保留。") }
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let schemaSignature = SHA256.hash(data: schemaData).map { String(format: "%02x", $0) }.joined()
        let invalid = try sqlite(database, "SELECT count(*) FROM cursorDiskKV WHERE key GLOB 'composerData:*' AND NOT json_valid(CAST(value AS TEXT));").trimmingCharacters(in: .whitespacesAndNewlines)
        guard invalid == "0" else { throw AICleanupError.command("Cursor 包含未知编码的会话，全部保留。") }
        let roots = try sqliteRows(database, """
            SELECT h.composerId AS id,
              json_extract(CAST(c.value AS TEXT),'$.composerId') AS rootID,
              json_extract(CAST(c.value AS TEXT),'$._v') AS rootVersion,
              MAX(COALESCE(h.lastUpdatedAt,0),COALESCE(h.createdAt,0),
                  COALESCE(json_extract(CAST(c.value AS TEXT),'$.lastUpdatedAt'),0),
                  COALESCE(json_extract(CAST(c.value AS TEXT),'$.createdAt'),0)) AS updated,
              json_extract(CAST(c.value AS TEXT),'$.status') AS status,
              json_extract(CAST(c.value AS TEXT),'$.isDraft') AS isDraft,
              json_extract(CAST(c.value AS TEXT),'$.isProject') AS isProject,
              json_extract(CAST(c.value AS TEXT),'$.isEphemeral') AS isEphemeral,
              json_extract(CAST(c.value AS TEXT),'$.gitWorktree.worktreePath') IS NOT NULL AS hasWorktree,
              json_extract(CAST(c.value AS TEXT),'$.createdFromBackgroundAgent.bcId') IS NOT NULL AS hasCloudAgent,
              COALESCE(json_extract(CAST(c.value AS TEXT),'$.subComposerIds'),'[]') AS subComposers,
              COALESCE(json_extract(CAST(c.value AS TEXT),'$.subagentComposerIds'),'[]') AS subagents,
              json_extract(CAST(c.value AS TEXT),'$.subagentInfo.parentComposerId') AS parent,
              json_extract(CAST(c.value AS TEXT),'$.subagentInfo.rootParentConversationId') AS rootParent
            FROM composerHeaders h LEFT JOIN cursorDiskKV c ON c.key='composerData:'||h.composerId ORDER BY h.composerId;
            """)
        let counts = try sqlite(database, "SELECT (SELECT count(*) FROM cursorDiskKV WHERE key GLOB 'composerData:*')-(SELECT count(*) FROM composerHeaders);").trimmingCharacters(in: .whitespacesAndNewlines)
        guard counts == "0", roots.count <= 10_000 else { throw AICleanupError.command("Cursor 根记录与会话索引不一致，全部保留。") }
        let ids = Set(roots.compactMap { $0["id"] as? String })
        guard ids.count == roots.count else { throw AICleanupError.command("Cursor 会话索引存在重复项，全部保留。") }
        try rejectLegacyCursorWorkspaceIndexes(home, budget: limit)
        var plans: [AICursorSession] = []
        for row in roots {
            try limit.visit()
            guard let id = row["id"] as? String, row["rootID"] as? String == id,
                  let version = row["rootVersion"] as? Int, [16, 17, 18].contains(version),
                  let updated = row["updated"] as? NSNumber, updated.int64Value > 0 else { throw AICleanupError.command("Cursor 会话版本或索引关系尚未识别，全部保留。") }
            var references: Set<String> = []
            for name in ["subComposers", "subagents"] {
                guard let encoded = row[name] as? String, let data = encoded.data(using: .utf8),
                      let values = try JSONSerialization.jsonObject(with: data) as? [String] else { throw AICleanupError.command("Cursor 关联会话格式未知，全部保留。") }
                references.formUnion(values)
            }
            for name in ["parent", "rootParent"] { if let value = row[name] as? String, !value.isEmpty { references.insert(value) } }
            references.remove(id)
            let unknown = references.subtracting(ids)
            var reason: String?
            if UUID(uuidString: id) == nil { reason = "Cursor 内部或未知标识的会话保留" }
            else if !unknown.isEmpty { reason = "关联会话索引不完整，保留" }
            else if (row["isDraft"] as? NSNumber)?.boolValue == true { reason = "尚未发送的草稿保留" }
            else if (row["isProject"] as? NSNumber)?.boolValue == true || (row["isEphemeral"] as? NSNumber)?.boolValue == true { reason = "项目或临时会话保留" }
            else if (row["hasWorktree"] as? NSNumber)?.boolValue == true || (row["hasCloudAgent"] as? NSNumber)?.boolValue == true { reason = "关联工作树或云端 Agent 的会话保留" }
            else if !["completed", "aborted", "none"].contains(row["status"] as? String ?? "") { reason = "正在生成或状态未知的会话保留" }
            let predicate = UUID(uuidString: id) == nil ? "key=" + sqlString("composerData:" + id) : try cursorKeyPredicate(id)
            let size = try sqliteRows(database, "SELECT count(*) AS rows,COALESCE(sum(length(CAST(key AS BLOB))+length(CAST(value AS BLOB))),0) AS bytes FROM cursorDiskKV WHERE " + predicate + ";").first
            let rows = (size?["rows"] as? NSNumber)?.intValue ?? 0
            let bytes = (size?["bytes"] as? NSNumber)?.int64Value ?? 0
            plans.append(AICursorSession(composerID: id, rootVersion: version, updatedAtMilliseconds: updated.int64Value,
                bytes: bytes, rowCount: rows + 1, referencedIDs: references, eligibility: reason, schemaSignature: schemaSignature))
        }
        // Treat parent/child links as an undirected review group; do not leave a referenced child behind.
        let edges = plans.flatMap { plan in plan.referencedIDs.map { (plan.composerID, $0) } }
        for (source, target) in edges {
            if let index = plans.firstIndex(where: { $0.composerID == target }) { plans[index].referencedIDs.insert(source) }
        }
        var held = Set(plans.filter { $0.eligibility != nil }.map(\.composerID))
        var changed = true
        while changed {
            changed = false
            for index in plans.indices where plans[index].eligibility == nil && !plans[index].referencedIDs.isDisjoint(with: held) {
                plans[index].eligibility = "关联会话仍须保留，本组暂不清理"
                held.insert(plans[index].composerID); changed = true
            }
        }
        return plans
    }
    static func rejectLegacyCursorWorkspaceIndexes(_ home: URL, budget: AIBudget) throws {
        let root = home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        guard exists(root) else { return }
        for folder in try children(root) {
            try budget.visit()
            let file = folder.appendingPathComponent("state.vscdb")
            guard exists(file) else { continue }
            try noSymlinks(file)
            guard try schemaColumns(file, table: "ItemTable") == ["key", "value"] else { throw AICleanupError.command("存在未知工作区数据库，Cursor 会话保留。") }
            let references = try sqlite(file, "SELECT count(*) FROM ItemTable WHERE key IN ('composer.composerData','composer.composerHeaders') AND length(value)>2;").trimmingCharacters(in: .whitespacesAndNewlines)
            if references != "0" { throw AICleanupError.command("存在旧版工作区会话索引，先由 Cursor 完成迁移；本次保留。") }
        }
    }
    static func validateCursorSelection(_ plans: [AICursorSession], catalog: [AICursorSession]) throws {
        let selected = Set(plans.map(\.composerID))
        guard !plans.isEmpty, plans.allSatisfy({ $0.eligibility == nil && catalog.contains($0) }) else { throw AICleanupError.changed("Cursor 会话索引") }
        for plan in catalog {
            let links = plan.referencedIDs
            if selected.contains(plan.composerID) {
                guard links.isSubset(of: selected) else { throw AICleanupError.conflict("有关联的 Cursor 会话未选择，已全部保留。") }
            } else if !links.isDisjoint(with: selected) { throw AICleanupError.conflict("其他 Cursor 会话仍引用选中会话，已全部保留。") }
        }
    }
    static func cursorDeleteSQL(_ plans: [AICursorSession]) throws -> String {
        let clauses = try plans.map { try cursorKeyPredicate($0.composerID) }.joined(separator: " OR ")
        let ids = plans.map { sqlString($0.composerID) }.joined(separator: ",")
        // Content-addressed agentKv:blob/agentKv:artifact and workspace inlineDiff are shared and remain intact.
        return "DELETE FROM cursorDiskKV WHERE " + clauses + "; DELETE FROM composerHeaders WHERE composerId IN (" + ids + ");"
    }
    static func visualizationThreadID(_ image: URL, home: URL) -> String? {
        let root = home.appendingPathComponent(".codex/visualizations")
        guard within(image, root), image != root, ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic"].contains(image.pathExtension.lowercased()) else { return nil }
        let components = String(image.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        guard components.count >= 5, components[0].count == 4, components[1].count == 2, components[2].count == 2,
              let year = Int(components[0]), let month = Int(components[1]), let day = Int(components[2]),
              (2020...2100).contains(year), (1...12).contains(month), (1...31).contains(day),
              let id = UUID(uuidString: components[3]),
              !components.dropFirst(4).dropLast().contains(where: { protectedNames.contains($0.lowercased()) || $0.lowercased() == "attachments" }) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return id.uuidString.lowercased()
    }
    static func codexReferences(_ home: URL, budget: AIBudget? = nil) throws -> AICodexReferences {
        let limit = budget ?? AIBudget(maximum: 100_000, seconds: 30)
        guard let database = try codexDatabase(home), database.lastPathComponent == "state_5.sqlite",
              try Set(schemaColumns(database, table: "threads")).isSuperset(of: ["id", "rollout_path"]),
              try schemaColumns(database, table: "thread_attachments") == ["id", "thread_id", "attachment_type", "identity_key", "payload", "created_at"] else { throw AICleanupError.command("无法完整识别 Codex 会话与附件索引，图片保留。") }
        var ids = Set<String>()
        for row in try sqliteRows(database, "SELECT id FROM threads UNION SELECT thread_id AS id FROM thread_attachments;") {
            try limit.visit()
            guard let id = row["id"] as? String else { throw AICleanupError.command("Codex 索引标识格式未知，图片保留。") }
            ids.insert(id.lowercased())
        }
        let desktop = home.appendingPathComponent(".codex/sqlite/codex-dev.db")
        if exists(desktop) {
            let desktopColumns: [String: [String]] = [
                "local_thread_catalog": ["host_id", "thread_id", "display_title", "source_created_at", "source_updated_at", "cwd", "source_kind", "source_detail", "model_provider", "git_branch", "observation_sequence", "missing_candidate", "thread_source", "source_recency_at", "pending_observed_title", "project_id", "conversation_origin", "trial_conversation_type", "chatgpt_async_status"],
                "live_visualization_suggestions": ["account_id", "user_id", "host_id", "thread_id", "id", "title", "description", "status", "submission", "turn_id", "creation_turn_id"],
                "thread_timeline_ledger": ["host_id", "thread_id", "sequence", "record_id", "payload_json"],
                "local_thread_catalog_scan_entries": ["host_id", "thread_id", "removed"]]
            for table in desktopColumns.keys.sorted() {
                guard try schemaColumns(desktop, table: table) == desktopColumns[table] else { throw AICleanupError.command("Codex 桌面索引版本未知，图片保留。") }
                for row in try sqliteRows(desktop, "SELECT DISTINCT thread_id FROM \(table);") {
                    try limit.visit()
                    guard let id = row["thread_id"] as? String else { throw AICleanupError.command("Codex 桌面索引标识未知，图片保留。") }
                    ids.insert(id.lowercased())
                }
            }
        }
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        if exists(index) {
            try noSymlinks(index)
            guard try stat(index).value.st_size <= 32 * 1024 * 1024 else { throw AICleanupError.budget }
            for line in try Data(contentsOf: index).split(separator: 10) where !line.isEmpty {
                try limit.visit()
                guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = row["id"] as? String else { throw AICleanupError.command("Codex 会话索引不完整，图片保留。") }
                ids.insert(id.lowercased())
            }
        }
        for suffix in [".codex/sessions", ".codex/archived_sessions"] {
            let root = home.appendingPathComponent(suffix)
            guard exists(root) else { continue }
            try noSymlinks(root)
            var readError: Error?
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in readError = error; return false }) else { throw AICleanupError.unsafe(root.path) }
            while let file = iterator.nextObject() as? URL {
                try limit.visit()
                if file.lastPathComponent.hasPrefix("rollout-"), file.pathExtension == "jsonl", let id = codexThreadID(file) { ids.insert(id.lowercased()); continue }
                _ = try stat(file) // An unreadable directory or symlink makes the absence check incomplete.
            }
            if let readError { throw readError }
        }
        for key in ["CODEX_THREAD_ID", "CODEX_CONVERSATION_ID"] {
            if let id = ProcessInfo.processInfo.environment[key], UUID(uuidString: id) != nil { ids.insert(id.lowercased()) }
        }
        return AICodexReferences(ids: ids, database: database)
    }
    static func digestFile(_ string: String) -> Bool { string.range(of: "^sha256-[0-9a-f]{64}$", options: .regularExpression) != nil }
    static func ollamaManifests(_ home: URL, budget: AIBudget? = nil) throws -> [AIManifest] {
        let models = home.appendingPathComponent(".ollama/models"), root = models.appendingPathComponent("manifests")
        guard exists(root) else { return [] }
        try noSymlinks(root)
        var manifests: [AIManifest] = []
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        for case let file as URL in iterator {
            try budget?.visit()
            let value = try stat(file)
            if value.isDirectory { continue }
            try noSymlinks(file)
            guard value.value.st_size <= 1024 * 1024 else { throw AICleanupError.unsafe(file.path) }
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = object["layers"] as? [[String: Any]], let config = object["config"] as? [String: Any] else { throw AICleanupError.unsafe(file.path) }
            var blobs: [URL] = []
            for entry in layers + [config] {
                guard let digest = entry["digest"] as? String, digest.hasPrefix("sha256:") else { throw AICleanupError.unsafe(file.path) }
                let name = digest.replacingOccurrences(of: ":", with: "-")
                guard digestFile(name) else { throw AICleanupError.unsafe(file.path) }
                let blob = models.appendingPathComponent("blobs/" + name)
                try noSymlinks(blob); _ = try stat(blob); blobs.append(blob)
            }
            manifests.append(AIManifest(url: file, blobs: Array(Set(blobs))))
        }
        return manifests
    }
}

private final class AILock {
    private var descriptor: Int32
    init(_ url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AICleanupError.unsafe(url.path) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; throw AICleanupError.busy("另一项 AI 清理或恢复") }
    }
    func unlock() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { unlock() }
}
private enum AICommand {
    final class Output: @unchecked Sendable {
        let lock = NSLock(); var data = Data(); var overflowed = false
        func append(_ value: Data) {
            lock.lock(); defer { lock.unlock() }
            let remaining = max(0, 2 * 1024 * 1024 - data.count)
            if value.count > remaining { overflowed = true }
            data.append(value.prefix(remaining))
        }
        func exceededLimit() -> Bool { lock.lock(); defer { lock.unlock() }; return overflowed }
        func value() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    acceptedExits: Set<Int32> = [0]) throws -> String {
        let process = Process(), pipe = Pipe(), collector = Output(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }; collector.append(data)
            }
            done.signal()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false, cancelled = false
        while process.isRunning {
            if Task<Never, Never>.isCancelled || ProcessInfo.processInfo.systemUptime > deadline {
                cancelled = Task<Never, Never>.isCancelled; timedOut = !cancelled
                process.terminate(); usleep(100_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; break
            }
            usleep(10_000)
        }
        process.waitUntilExit(); _ = done.wait(timeout: .now() + 1)
        let output = String(data: collector.value(), encoding: .utf8) ?? ""
        if cancelled { throw AICleanupError.cancelled }
        if collector.exceededLimit() { throw AICleanupError.budget }
        guard !timedOut, acceptedExits.contains(process.terminationStatus) else { throw AICleanupError.command(timedOut ? "操作超时，已停止。" : String(output.prefix(1000))) }
        return output
    }
}

// Metadata-only unified scanning shares the exact admission and version-preservation policy.
enum AIInventoryPolicy {
    static var cacheRoots: [(AITool, String)] { AIPaths.cacheRoots }
    static var versionRoots: [(tool: AITool, root: String, entry: String)] {
        AIPaths.cliVersionRoots.map { ($0.tool, $0.root, $0.entry) }
    }
    static var protectedNames: Set<String> { AIPaths.protectedNames }
    static func insideApplication(_ url: URL, root: URL) -> Bool { AIPaths.insideApplication(url, root: root) }
    static func versionComponents(_ name: String, tool: AITool) -> [Int]? { AIPaths.versionComponents(name, tool: tool) }
    static func preservedVersions(_ files: [URL], tool: AITool, root: String, entry: String, home: URL) throws -> Set<String> {
        try AIPaths.preservedVersions(files, location: AICLIVersionRoot(tool: tool, root: root, entry: entry), home: home)
    }
}
