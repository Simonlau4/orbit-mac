import Foundation
import Darwin

public enum UnifiedCleanupSection: String, CaseIterable, Codable, Sendable {
    case applications, communication, developer, ai, system, trash, installers, manual
    public var title: String {
        switch self {
        case .applications: return "App 缓存与日志"
        case .communication: return "通讯工具"
        case .developer: return "开发工具"
        case .ai: return "AI 工具"
        case .system: return "系统数据"
        case .trash: return "废纸篓"
        case .installers: return "旧安装包"
        case .manual: return "手动管理"
        }
    }
    public var detail: String {
        switch self {
        case .applications: return "应用与浏览器缓存、旧日志；运行中与近期内容保留"
        case .communication: return "聊天工具占用；聊天媒体和运行中的缓存保留"
        case .developer: return "构建及软件包缓存；未知活动的构建只统计占用"
        case .ai: return "缓存与旧版本统一统计，进入 AI 审阅后再选择"
        case .system: return "系统缓存、模拟器缓存及诊断日志，单独管理员处理"
        case .trash: return "已有废纸篓占用；清空将永久删除，本页仅统计"
        case .installers: return "下载目录中的旧 DMG 和 PKG"
        case .manual: return "浏览器离线数据、共享缓存等保留内容"
        }
    }
}

public enum UnifiedCleanupHandling: String, Codable, Sendable {
    case ordinary, aiReview, systemReview, trashReview, retained
}

public struct UnifiedCleanupEntry: Identifiable, Sendable {
    public let id: String
    public let section: UnifiedCleanupSection
    public let title: String
    public let url: URL
    public let bytes: Int64?
    public let fileCount: Int
    public let isPartial: Bool
    public let detail: String
    public let handling: UnifiedCleanupHandling
    public let ordinaryGroupID: String?
    public var countedBytes: Int64? = nil
}

public struct UnifiedCleanupFile: Codable, Sendable {
    public let url: URL
    public let section: UnifiedCleanupSection
    public let bytes: Int64
    public let device: UInt64
    public let inode: UInt64
    public var identity: String { "\(device):\(inode)" }
}

public struct UnifiedInventoryRoot: Sendable {
    public let url: URL
    public let title: String
    public let section: UnifiedCleanupSection
    public let detail: String
    public init(url: URL, title: String, section: UnifiedCleanupSection, detail: String) {
        self.url = url; self.title = title; self.section = section; self.detail = detail
    }
}

public struct UnifiedCleanupScan: Sendable {
    public let ordinary: CleanupScan
    public let ai: AIInventoryScan
    public let extended: ExtendedCleanupScan
    public let entries: [UnifiedCleanupEntry]
    public let files: [UnifiedCleanupFile]
    public let issues: [CleanupScanIssue]
    public let isPartial: Bool
    public let partialSections: Set<UnifiedCleanupSection>
    public let countedBytes: Int64
    private let sectionTotals: [UnifiedCleanupSection: Int64]
    public func bytes(in section: UnifiedCleanupSection) -> Int64 { sectionTotals[section] ?? 0 }

    public init(ordinary: CleanupScan, ai: AIInventoryScan, extended: ExtendedCleanupScan,
                supplemental: ExtendedCleanupScan? = nil, supplementalRoots: [UnifiedInventoryRoot] = [],
                discoveryIssues: [CleanupScanIssue] = []) {
        self.ordinary = ordinary; self.ai = ai; self.extended = extended
        var rows: [UnifiedCleanupEntry] = [], files: [UnifiedCleanupFile] = [], identities: Set<String> = []
        var partial: Set<UnifiedCleanupSection> = []
        var rowFiles: [String: Set<String>] = [:]
        func identity(_ device: Int32, _ inode: UInt64) -> String { "\(UInt64(bitPattern: Int64(device))):\(inode)" }
        let aiFilesByItem = Dictionary(grouping: ai.metadataFiles, by: \.itemID)
        var retainedFiles: [String: Set<String>] = [:]
        for file in ordinary.metadataFiles {
            if let reason = file.retainedReason {
                let key = "\(reason.rawValue)|\(file.category.rawValue)|\(file.rootURL.path)"
                retainedFiles[key, default: []].insert(identity(file.device, file.inode))
            }
        }
        func add(_ url: URL, section: UnifiedCleanupSection, bytes: Int64, device: UInt64, inode: UInt64) {
            let item = UnifiedCleanupFile(url: url, section: section, bytes: bytes, device: device, inode: inode)
            if identities.insert(item.identity).inserted { files.append(item) }
        }
        for item in ai.items {
            rows.append(UnifiedCleanupEntry(id: "ai|" + item.id, section: .ai, title: item.tool.title + " · " + item.url.lastPathComponent,
                url: item.url, bytes: item.disposition == .unavailable && item.fileCount == 0 ? nil : item.bytes,
                fileCount: item.fileCount, isPartial: item.isPartial, detail: item.reason, handling: .aiReview, ordinaryGroupID: nil))
            rowFiles["ai|" + item.id] = Set((aiFilesByItem[item.id] ?? []).map(\.identity))
        }
        for file in ai.metadataFiles { add(file.url, section: .ai, bytes: file.bytes, device: file.device, inode: file.inode) }
        if ai.isPartial { partial.insert(.ai) }
        for scan in [extended] + (supplemental.map { [$0] } ?? []) {
            for item in scan.items {
                let root = supplementalRoots.first { $0.url.path == item.rootURL.path }
                let section = root?.section ?? (item.section == .trash ? .trash : .system)
                let detail = root?.detail ?? (item.access == .missing ? "目录不存在" : item.access == .duplicate ? "已在其他路径统计" : section.detail)
                rows.append(UnifiedCleanupEntry(id: "inventory|" + item.id, section: section, title: root?.title ?? item.title,
                    url: item.url, bytes: item.logicalBytes, fileCount: item.fileCount, isPartial: item.isPartial,
                    detail: detail, handling: root == nil ? (section == .trash ? .trashReview : .systemReview) : .retained, ordinaryGroupID: nil))
                rowFiles["inventory|" + item.id] = Set(item.files.map { "\($0.device):\($0.inode)" })
                for file in item.files { add(file.url, section: section, bytes: file.logicalBytes, device: file.device, inode: file.inode) }
                if item.isPartial { partial.insert(section) }
            }
        }
        for group in ordinary.groups {
            let section = Self.section(for: group.items.first?.url ?? URL(fileURLWithPath: "/"), category: group.category)
            rows.append(UnifiedCleanupEntry(id: "ordinary|" + group.id, section: section, title: group.name,
                url: group.items.first?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"), bytes: group.bytes,
                fileCount: group.items.count, isPartial: false, detail: "可移入废纸篓 · " + group.category.title,
                handling: .ordinary, ordinaryGroupID: group.id))
            rowFiles["ordinary|" + group.id] = Set(group.items.map { "\($0.fingerprint.device):\($0.fingerprint.inode)" })
        }
        for item in ordinary.retained {
            let baseSection = Self.section(for: item.rootURL, category: item.category)
            let section: UnifiedCleanupSection = item.reason == .unknownOwner || (item.reason == .protectedData && baseSection != .communication) ? .manual : baseSection
            let detail: String
            switch item.reason {
            case .runningApplication: detail = "运行中，保留"
            case .recent: detail = "未达到保留天数"
            case .hardLink: detail = "共享硬链接，保留"
            case .unknownOwner: detail = "共享缓存归属未核实，保留"
            case .protectedData: detail = "数据库或离线内容，仅统计占用并保留"
            }
            rows.append(UnifiedCleanupEntry(id: "retained|" + item.id, section: section, title: item.rootURL.lastPathComponent,
                url: item.rootURL, bytes: item.isPartial && item.count == 0 ? nil : item.bytes, fileCount: item.count,
                isPartial: item.isPartial, detail: detail, handling: .retained, ordinaryGroupID: nil))
            rowFiles["retained|" + item.id] = retainedFiles["\(item.reason.rawValue)|\(item.category.rawValue)|\(item.rootURL.path)"] ?? []
            if item.isPartial { partial.insert(section) }
        }
        for file in ordinary.metadataFiles {
            let baseSection = Self.section(for: file.url, category: file.category)
            let section: UnifiedCleanupSection = file.retainedReason == .unknownOwner || (file.retainedReason == .protectedData && baseSection != .communication) ? .manual : baseSection
            add(file.url, section: section, bytes: file.bytes, device: UInt64(bitPattern: Int64(file.device)), inode: file.inode)
        }
        var issueIDs: Set<String> = []
        issues = (ordinary.issues + ai.issues + extended.issues + (supplemental?.issues ?? []) + discoveryIssues).filter { issueIDs.insert($0.id).inserted }
        if ordinary.isPartial {
            partial.formUnion([.applications, .communication, .developer, .installers, .manual])
        }
        if !discoveryIssues.isEmpty { partial.formUnion([.communication, .developer, .manual]) }
        let byIdentity = Dictionary(uniqueKeysWithValues: files.map { ($0.identity, $0) })
        var credited: Set<String> = []
        for index in rows.indices where rows[index].bytes != nil {
            let section = rows[index].section
            let contribution = (rowFiles[rows[index].id] ?? []).compactMap { key -> UnifiedCleanupFile? in
                guard let file = byIdentity[key], file.section == section, credited.insert(key).inserted else { return nil }
                return file
            }
            rows[index].countedBytes = contribution.reduce(0) { $0 + $1.bytes }
        }
        self.entries = rows.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        self.files = files; self.partialSections = partial
        var totals: [UnifiedCleanupSection: Int64] = [:]
        for file in files { totals[file.section, default: 0] += file.bytes }
        sectionTotals = totals; countedBytes = totals.values.reduce(0, +)
        isPartial = ordinary.isPartial || ai.isPartial || extended.isPartial || (supplemental?.isPartial ?? false) || !discoveryIssues.isEmpty
    }

    static func section(for url: URL, category: CleanupCategory) -> UnifiedCleanupSection {
        let parts = url.pathComponents.map { $0.lowercased() }
        if parts.contains(where: { ["lark", "larkshell", "feishu", "wechat", "weixin", "com.tencent.xinwechat", "com.tencent.wechat", "com.electron.lark", "dingtalk", "com.alibaba.dingtalk", "telegram", "com.tencent.qq"].contains($0) }) { return .communication }
        switch category {
        case .developer, .packageCache: return .developer
        case .installers: return .installers
        default: return .applications
        }
    }
}

public actor UnifiedCleanupScanner {
    private let home: URL
    private let includeRecentCaches: Bool
    private let categories: Set<CleanupCategory>?
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, includeRecentCaches: Bool = false, categories: Set<CleanupCategory>? = nil) {
        self.home = home; self.includeRecentCaches = includeRecentCaches; self.categories = categories
    }

    public func scan(runningBundleIDs: Set<String> = []) async -> UnifiedCleanupScan {
        var discoveryIssues: [CleanupScanIssue] = []
        let supplemental = Self.inventoryRoots(home: home, issues: &discoveryIssues)
        let excluded = AIInventoryScanner.coveredRoots(home: home) + supplemental.map(\.url)
        let ordinaryScope = CleanupPolicy.production(home: home, includeRecentCaches: includeRecentCaches, categories: categories, excludedRoots: excluded)
        let policy = CleanupPolicy(roots: ordinaryScope.roots, maximumFiles: 600_000,
            discoveryIssues: ordinaryScope.discoveryIssues, excludedRoots: excluded)
        async let ordinary = CleanupScanner(policy: policy).scan(runningBundleIDs: runningBundleIDs)
        async let ai = AIInventoryScanner(home: home).scan()
        async let extended = ExtendedCleanupScanner(policy: .production(home: home)).scan()
        async let inventory = ExtendedCleanupScanner(policy: ExtendedCleanupPolicy(systemRoots: supplemental.map { ExtendedCleanupRoot(url: $0.url, title: $0.title) }, trashRoots: [])).scan()
        let builds = categories?.contains(.developer) ?? true ? Self.buildCandidates(supplemental, minimumAgeDays: includeRecentCaches ? 0 : 7) : []
        let found = Set(builds.map(\.url.path))
        let roots = supplemental.map { found.contains($0.url.path) ? UnifiedInventoryRoot(url: $0.url, title: $0.title, section: $0.section, detail: "可移入废纸篓的项目构建产物") : $0 }
        return await UnifiedCleanupScan(ordinary: Self.adding(builds, to: ordinary), ai: ai, extended: extended, supplemental: inventory, supplementalRoots: roots, discoveryIssues: discoveryIssues)
    }

    /// Project build folders found by discovery; the trash admission roots for build candidates.
    public static func buildOutputRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var issues: [CleanupScanIssue] = []
        return inventoryRoots(home: home, issues: &issues).filter(isBuildOutput).map(\.url)
    }

    static func isBuildOutput(_ root: UnifiedInventoryRoot) -> Bool { root.section == .developer && BuildOutputs.names.contains(root.url.lastPathComponent) }

    static func buildCandidates(_ roots: [UnifiedInventoryRoot], minimumAgeDays: Int) -> [CleanupItem] {
        let builds = roots.filter(isBuildOutput)
        guard !builds.isEmpty, let directories = BuildOutputs.workingDirectories() else { return [] }
        return builds.compactMap { BuildOutputs.candidate($0.url, minimumAgeDays: minimumAgeDays, workingDirectories: directories) }
    }

    static func adding(_ builds: [CleanupItem], to scan: CleanupScan) -> CleanupScan {
        guard !builds.isEmpty else { return scan }
        let groups = builds.map { CleanupGroup(id: "build|" + $0.url.path, name: $0.url.deletingLastPathComponent().lastPathComponent + " · " + $0.name, category: .developer, items: [$0]) }
        return CleanupScan(items: scan.items + builds, warnings: scan.warnings, scannedFiles: scan.scannedFiles, isPartial: scan.isPartial,
            scannedBytes: scan.scannedBytes, groups: (scan.groups + groups).sorted { $0.bytes > $1.bytes }, blockedCount: scan.blockedCount,
            issues: scan.issues, retained: scan.retained, visitedEntries: scan.visitedEntries, metadataFiles: scan.metadataFiles)
    }

    static func inventoryRoots(home: URL, issues: inout [CleanupScanIssue]) -> [UnifiedInventoryRoot] {
        var roots = [
            UnifiedInventoryRoot(url: home.appendingPathComponent(".cache/uv/builds-v0"), title: "uv 临时构建", section: .developer, detail: "构建活动未核实，仅统计占用"),
            UnifiedInventoryRoot(url: home.appendingPathComponent(".npm/_npx"), title: "npx 程序缓存", section: .developer, detail: "可能仍在使用，仅统计占用"),
            UnifiedInventoryRoot(url: home.appendingPathComponent(".npm/_logs"), title: "npm 日志", section: .developer, detail: "仅统计占用"),
            UnifiedInventoryRoot(url: home.appendingPathComponent(".config/gcloud/logs"), title: "Google Cloud 日志", section: .developer, detail: "仅统计占用"),
            UnifiedInventoryRoot(url: home.appendingPathComponent(".cache/gh"), title: "GitHub CLI 缓存", section: .developer, detail: "仅统计占用")
        ]
        roots += [
            UnifiedInventoryRoot(url: home.appendingPathComponent(".cursor/extensions"), title: "Cursor 已安装扩展", section: .ai, detail: "扩展仍可能在使用，仅统计并保留"),
            UnifiedInventoryRoot(url: home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage"), title: "Cursor 工作区状态", section: .ai, detail: "含工作区数据库，仅统计并保留"),
            UnifiedInventoryRoot(url: home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage"), title: "VS Code 工作区状态", section: .developer, detail: "含工作区数据库，仅统计并保留"),
            UnifiedInventoryRoot(url: home.appendingPathComponent("Library/Application Support/CrashReporter"), title: "应用崩溃报告", section: .applications, detail: "报告状态，仅统计并保留"),
            UnifiedInventoryRoot(url: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.orbitmac.Orbit.FanAgent"), title: "Orbit 温控组件", section: .manual, detail: "Orbit 已安装组件，归属明确，保留"),
            UnifiedInventoryRoot(url: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.orbitmac.Orbit.UpdateAgent"), title: "Orbit 更新组件", section: .manual, detail: "Orbit 已安装组件，归属明确，保留")
        ]
        for file in CleanupScopeDiscovery.children(home.appendingPathComponent(".local/bin"), issues: &issues, includeRegularFiles: true)
            where file.lastPathComponent.range(of: "\\.[0-9]{16,20}\\.old$", options: .regularExpression) != nil {
            roots.append(UnifiedInventoryRoot(url: file, title: "命令更新副本 · " + file.lastPathComponent,
                section: .manual, detail: "旧可执行文件归属需核实，仅统计并保留"))
        }
        let browser = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        let profiles = CleanupScopeDiscovery.children(browser, issues: &issues)
        if !profiles.isEmpty {
            for profile in profiles where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") {
                for leaf in ["CacheStorage", "ScriptCache"] {
                    roots.append(UnifiedInventoryRoot(url: profile.appendingPathComponent("Service Worker/" + leaf), title: "Chrome " + profile.lastPathComponent + " · " + leaf,
                        section: .manual, detail: "浏览器离线数据，保留"))
                }
            }
        }
        for app in ["LarkShell", "Lark", "Feishu"] {
            let users = home.appendingPathComponent("Library/Application Support/" + app + "/aha/users")
            for user in CleanupScopeDiscovery.children(users, issues: &issues) {
                for suffix in ["Service Worker/CacheStorage", "GPUCache"] {
                    roots.append(UnifiedInventoryRoot(url: user.appendingPathComponent("profile_explorer/" + suffix), title: "Feishu · " + suffix,
                        section: .communication, detail: "聊天工具缓存，仅统计占用并保留"))
                }
            }
        }
        var projects = CleanupScopeDiscovery.children(home.appendingPathComponent("Developer"), issues: &issues)
        for (base, depth) in [(".codex/worktrees", 2), ("Documents/Codex", 3)] {
            var level = [home.appendingPathComponent(base)]
            var discovered = 0
            for _ in 0..<depth {
                var next: [URL] = []
                for parent in level {
                    for child in CleanupScopeDiscovery.children(parent, issues: &issues) {
                        let name = child.lastPathComponent
                        guard !name.hasPrefix("."), !["node_modules", "vendor", "dist"].contains(name) else { continue }
                        var value = stat()
                        guard lstat(child.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { continue }
                        discovered += 1
                        if discovered > 2_000 { break }
                        projects.append(child); next.append(child)
                    }
                    if discovered > 2_000 { break }
                }
                level = next
                if discovered > 2_000 {
                    issues.append(CleanupScanIssue(kind: .limit, path: home.appendingPathComponent(base).path, message: "工作目录发现达到 2000 个目录上限"))
                    break
                }
            }
        }
        for project in projects where !project.lastPathComponent.hasPrefix(".") && project.lastPathComponent != "vendor" {
            for suffix in [".build", ".next", "DerivedData"] {
                let url = project.appendingPathComponent(suffix)
                var value = stat()
                let result = lstat(url.path, &value)
                if result == 0, value.st_mode & S_IFMT == S_IFDIR || value.st_mode & S_IFMT == S_IFLNK {
                    roots.append(UnifiedInventoryRoot(url: url, title: project.lastPathComponent + " · " + suffix,
                        section: .developer, detail: "项目构建活动未核实，仅统计占用"))
                } else if result != 0 && errno != ENOENT && errno != ENOTDIR {
                    issues.append(.reading(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), at: url))
                }
            }
        }
        return roots
    }
}
