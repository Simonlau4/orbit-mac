import Foundation
import Darwin

public enum CleanupCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case appCache, logs, developer, browserCache, packageCache, installers

    public var title: String {
        switch self {
        case .appCache: return "应用缓存"
        case .logs: return "历史日志"
        case .developer: return "开发构建缓存"
        case .browserCache: return "浏览器缓存"
        case .packageCache: return "软件包缓存"
        case .installers: return "旧安装包"
        }
    }
}

public struct FileFingerprint: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let mode: UInt16

    fileprivate init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        mode = value.st_mode
    }

    public var modifiedAt: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }

    public var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public var name: String { url.lastPathComponent }
    public let category: CleanupCategory
    public let bytes: Int64
    public let modifiedAt: Date
    public let fingerprint: FileFingerprint
    /// Set for whole folders (project build outputs); rechecked before the move.
    public var contents: CleanupContentStamp? = nil

    /// Prepares one explicitly selected file or directory. Admission is rechecked by TrashStore.
    public static func prepare(at url: URL, category: CleanupCategory = .appCache) throws -> CleanupItem {
        let source = CleanupPaths.normalized(url)
        try CleanupPaths.noSymlinks(source)
        try CleanupPaths.notProtected(source)
        let stamp = try CleanupPaths.fingerprint(source)
        guard stamp.mode & S_IFMT == S_IFREG || stamp.isDirectory else {
            throw CleanupError.unsupported(source.path)
        }
        let bytes: Int64
        if stamp.isDirectory {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            if let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys) {
                for case let file as URL in files {
                    guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
                    if values.isSymbolicLink == true { continue }
                    if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
                }
            }
            bytes = total
        } else {
            bytes = max(0, stamp.size)
        }
        return CleanupItem(url: source, category: category, bytes: bytes, modifiedAt: stamp.modifiedAt, fingerprint: stamp)
    }
}

public struct CleanupRoot: Sendable {
    public let url: URL
    public let category: CleanupCategory
    public let minimumAgeDays: Int
    public let recursive: Bool
    public let allowedExtensions: Set<String>?
    public let label: String?
    public let runningBundleID: String?
    public let inventoryOnly: Bool

    public init(url: URL, category: CleanupCategory, minimumAgeDays: Int,
                recursive: Bool = true, allowedExtensions: Set<String>? = nil,
                label: String? = nil, runningBundleID: String? = nil, inventoryOnly: Bool = false) {
        self.url = CleanupPaths.normalized(url)
        self.category = category
        self.minimumAgeDays = minimumAgeDays
        self.recursive = recursive
        self.allowedExtensions = allowedExtensions.map { Set($0.map { $0.lowercased() }) }
        self.label = label
        self.runningBundleID = runningBundleID
        self.inventoryOnly = inventoryOnly
    }
}

public struct CleanupPolicy: Sendable {
    public let roots: [CleanupRoot]
    public var writableRoots: [CleanupRoot] { roots.filter { !$0.inventoryOnly } }
    public let maximumFiles: Int
    public let maximumItems: Int
    public let timeLimit: TimeInterval
    public let discoveryIssues: [CleanupScanIssue]
    public let excludedRoots: [URL]

    public init(roots: [CleanupRoot], maximumFiles: Int = 300_000, maximumItems: Int = 200_000, timeLimit: TimeInterval = 45,
                discoveryIssues: [CleanupScanIssue] = [], excludedRoots: [URL] = []) {
        self.roots = roots
        self.maximumFiles = maximumFiles
        self.maximumItems = maximumItems
        self.timeLimit = timeLimit
        self.discoveryIssues = discoveryIssues
        self.excludedRoots = excludedRoots.map(CleanupPaths.normalized)
    }

    public static func production(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  includeRecentCaches: Bool = false,
                                  categories: Set<CleanupCategory>? = nil,
                                  installedApplications: [String: Set<String>]? = nil,
                                  excludedRoots: [URL] = []) -> CleanupPolicy {
        let cacheAge = includeRecentCaches ? 0 : 7
        var discoveryIssues: [CleanupScanIssue] = []
        let wantsCache = categories?.contains(.appCache) ?? true
        let wantsLogs = categories?.contains(.logs) ?? true
        var roots = [
            CleanupRoot(url: home.appendingPathComponent("Library/Caches"), category: .appCache, minimumAgeDays: cacheAge),
            CleanupRoot(url: home.appendingPathComponent("Library/Logs"), category: .logs, minimumAgeDays: 14),
            CleanupRoot(url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), category: .developer, minimumAgeDays: includeRecentCaches ? 0 : 30),
            CleanupRoot(url: home.appendingPathComponent(".npm/_cacache"), category: .packageCache, minimumAgeDays: cacheAge, label: "npm"),
            CleanupRoot(url: home.appendingPathComponent(".cache/pip"), category: .packageCache, minimumAgeDays: cacheAge, label: "pip"),
            CleanupRoot(url: home.appendingPathComponent(".bun/install/cache"), category: .packageCache, minimumAgeDays: cacheAge, label: "Bun"),
            CleanupRoot(url: home.appendingPathComponent(".cache/node/corepack"), category: .packageCache, minimumAgeDays: cacheAge, label: "Corepack"),
            CleanupRoot(url: home.appendingPathComponent("Library/Caches/node/corepack"), category: .packageCache, minimumAgeDays: cacheAge, label: "Corepack"),
            CleanupRoot(url: home.appendingPathComponent(".cache/fontconfig"), category: .appCache, minimumAgeDays: cacheAge, label: "Fontconfig"),
            CleanupRoot(url: home.appendingPathComponent("Library/Application Support/Google/GoogleUpdater/crx_cache"), category: .appCache,
                        minimumAgeDays: cacheAge, label: "Google Updater", runningBundleID: "com.google.Chrome"),
            CleanupRoot(url: home.appendingPathComponent("Library/Application Support/Google/Chrome/component_crx_cache"), category: .browserCache,
                        minimumAgeDays: cacheAge, label: "Chrome 组件缓存", runningBundleID: "com.google.Chrome"),
            CleanupRoot(url: home.appendingPathComponent("Library/Application Support/Google/Chrome/ShaderCache"), category: .browserCache,
                        minimumAgeDays: cacheAge, label: "Chrome 渲染缓存", runningBundleID: "com.google.Chrome"),
            CleanupRoot(url: home.appendingPathComponent("Downloads"), category: .installers, minimumAgeDays: 30,
                        recursive: false, allowedExtensions: ["dmg", "pkg"], label: "下载的安装包")
        ]
        let browsers = [
            ("Library/Application Support/Google/Chrome", "Google Chrome", "com.google.Chrome"),
            ("Library/Application Support/Microsoft Edge", "Microsoft Edge", "com.microsoft.edgemac")
        ]
        for (suffix, browser, bundleID) in browsers where categories?.contains(.browserCache) ?? true {
            let base = home.appendingPathComponent(suffix)
            // Select known cache subtrees, never the profile or its history/cookies.
            let profiles = CleanupScopeDiscovery.children(base, issues: &discoveryIssues, reportBrowserProfileLinks: true)
            for profile in profiles {
                let name = profile.lastPathComponent
                let isNumberedProfile = name.hasPrefix("Profile ") && Int(name.dropFirst(8)) != nil
                guard name == "Default" || isNumberedProfile else { continue }
                for cache in ["Cache", "Code Cache", "GPUCache", "DawnCache", "GraphiteDawnCache", "ShaderCache", "GrShaderCache"] {
                    roots.append(CleanupRoot(url: profile.appendingPathComponent(cache), category: .browserCache,
                                             minimumAgeDays: cacheAge, label: browser + " · " + name,
                                             runningBundleID: bundleID))
                }
            }
        }
        let containers = wantsCache || wantsLogs ? CleanupScopeDiscovery.children(home.appendingPathComponent("Library/Containers"), issues: &discoveryIssues) : []
        for container in containers {
            for (leaf, category, age) in [("Caches", CleanupCategory.appCache, cacheAge), ("Logs", .logs, 14)] {
                guard categories?.contains(category) ?? true else { continue }
                roots.append(CleanupRoot(url: container.appendingPathComponent("Data/Library/" + leaf), category: category,
                    minimumAgeDays: age, label: container.lastPathComponent, runningBundleID: container.lastPathComponent))
            }
        }
        let groups = wantsCache || wantsLogs ? CleanupScopeDiscovery.children(home.appendingPathComponent("Library/Group Containers"), issues: &discoveryIssues) : []
        for container in groups {
            for library in ["Library", "Data/Library"] {
                for (leaf, category, age) in [("Caches", CleanupCategory.appCache, cacheAge), ("Logs", .logs, 14)] {
                    guard categories?.contains(category) ?? true else { continue }
                    roots.append(CleanupRoot(url: container.appendingPathComponent(library + "/" + leaf), category: category,
                        minimumAgeDays: age, label: container.lastPathComponent, inventoryOnly: true))
                }
            }
        }
        let applications = wantsCache ? installedApplications ?? CleanupScopeDiscovery.installedApplications(home: home, issues: &discoveryIssues) : [:]
        var owners: [String: Set<String>] = [:]
        for (identifier, appNames) in applications {
            let aliases = CleanupRunningProtection.knownAliases.first(where: { key, values in
                key == identifier.lowercased() || values.contains { $0.lowercased() == identifier.lowercased() }
            })?.value ?? []
            for name in appNames.union(aliases).union([identifier]) where !name.contains("/") && !name.contains("\\") {
                owners[name.lowercased(), default: []].insert(identifier)
            }
        }
        let support = wantsCache ? CleanupScopeDiscovery.children(home.appendingPathComponent("Library/Application Support"), issues: &discoveryIssues) : []
        for app in support {
            let matching = owners[app.lastPathComponent.lowercased()] ?? []
            let owner = matching.count == 1 ? matching.first : nil
            for leaf in ["Cache", "Caches", "CachedData", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache", "ShaderCache", "GrShaderCache"] {
                roots.append(CleanupRoot(url: app.appendingPathComponent(leaf), category: .appCache,
                    minimumAgeDays: cacheAge, label: app.lastPathComponent, runningBundleID: owner, inventoryOnly: owner == nil))
            }
        }
        return CleanupPolicy(roots: roots.filter { categories?.contains($0.category) ?? true }, discoveryIssues: discoveryIssues, excludedRoots: excludedRoots)
    }
}

public struct CleanupGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: CleanupCategory
    public let items: [CleanupItem]
    public let bytes: Int64

    public init(id: String, name: String, category: CleanupCategory, items: [CleanupItem]) {
        self.id = id
        self.name = name
        self.category = category
        self.items = items
        self.bytes = items.reduce(0) { $0 + $1.bytes }
    }
}

public struct CleanupScan: Sendable {
    public let items: [CleanupItem]
    public let warnings: [String]
    public let scannedFiles: Int
    public let isPartial: Bool
    public let scannedBytes: Int64
    public let groups: [CleanupGroup]
    public let blockedCount: Int
    public let issues: [CleanupScanIssue]
    public let retained: [CleanupRetainedSummary]
    public let visitedEntries: Int
    public let metadataFiles: [CleanupScannedFile]
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public init(items: [CleanupItem], warnings: [String], scannedFiles: Int, isPartial: Bool,
                scannedBytes: Int64 = 0, groups: [CleanupGroup]? = nil, blockedCount: Int = 0,
                issues: [CleanupScanIssue] = [], retained: [CleanupRetainedSummary] = [], visitedEntries: Int = 0,
                metadataFiles: [CleanupScannedFile] = []) {
        self.items = items
        self.warnings = warnings
        self.scannedFiles = scannedFiles
        self.isPartial = isPartial
        self.scannedBytes = scannedBytes
        self.groups = groups ?? CleanupCategory.allCases.compactMap { category in
            let selected = items.filter { $0.category == category }
            return selected.isEmpty ? nil : CleanupGroup(id: category.rawValue, name: category.title, category: category, items: selected)
        }
        self.blockedCount = blockedCount
        self.issues = issues
        self.retained = retained
        self.visitedEntries = visitedEntries
        self.metadataFiles = metadataFiles
    }
}

public actor CleanupScanner {
    private let policy: CleanupPolicy
    private struct Identity: Hashable { let device: Int32; let inode: UInt64 }

    public init(policy: CleanupPolicy = .production()) { self.policy = policy }

    public func scan(runningBundleIDs: Set<String> = []) async -> CleanupScan {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, policy.timeLimit)
        var items: [CleanupItem] = []
        var warnings: [String] = []
        var scanned = 0
        var visited = 0
        var scannedBytes: Int64 = 0
        var metadataFiles: [CleanupScannedFile] = []
        var partial = false
        var blocked = 0
        var visitedPaths: Set<String> = []
        var completedRoots: Set<String> = []
        var groupItems: [String: [CleanupItem]] = [:]
        var groupLabels: [String: (String, CleanupCategory)] = [:]
        var issues: [CleanupScanIssue] = []
        var seenFiles: Set<Identity> = []
        var seenDirectories: Set<Identity> = []
        let excludedPaths = policy.excludedRoots.map(\.path)
        let excludedIdentities = Set(policy.excludedRoots.compactMap { url -> Identity? in
            var value = stat()
            guard lstat(url.path, &value) == 0 else { return nil }
            return Identity(device: value.st_dev, inode: UInt64(value.st_ino))
        })
        func isExcluded(_ path: String) -> Bool {
            excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var runningDirectories: [String: String] = [:]
        var protectedDirectories: Set<String> = []
        var retainedInfo: [String: (reason: CleanupRetainedReason, root: CleanupRoot, owner: String?)] = [:]
        var retainedTotals: [String: (count: Int, bytes: Int64)] = [:]
        var retainedPartialPaths: Set<String> = []
        func report(_ issue: CleanupScanIssue, isBlocked: Bool = false) {
            if isBlocked { blocked += 1; partial = true }
            if issue.kind == .limit || issue.kind == .cancelled { partial = true }
            let termination = issue.kind == .limit || issue.kind == .cancelled
            if !issues.contains(where: { $0.id == issue.id }) {
                if issues.count < 64 { issues.append(issue) }
                else if termination { issues[issues.lastIndex(where: { $0.kind == .permission || $0.kind == .io }) ?? 63] = issue }
            }
            if !warnings.contains(issue.message) {
                if warnings.count < 12 { warnings.append(issue.message) }
                else if termination { warnings[11] = issue.message }
            }
        }
        func retain(_ reason: CleanupRetainedReason, root: CleanupRoot, owner: String? = nil, bytes: Int64, count: Int = 1) {
            let key = "\(reason.rawValue)|\(root.category.rawValue)|\(root.url.path)|\(owner ?? "")"
            retainedInfo[key] = (reason, root, owner)
            let previous = retainedTotals[key] ?? (0, 0)
            retainedTotals[key] = (previous.count + count, previous.bytes + bytes)
        }
        func reachedLimit(at url: URL) -> CleanupScanIssue? {
            if Task.isCancelled { return CleanupScanIssue(kind: .cancelled, path: url.path, message: "扫描已取消；显示已读取的结果。") }
            let reason: String
            if ProcessInfo.processInfo.systemUptime >= deadline { reason = "\(policy.timeLimit) 秒时间" }
            else if visited >= policy.maximumFiles { reason = "\(policy.maximumFiles) 个路径" }
            else if items.count >= policy.maximumItems { reason = "\(policy.maximumItems) 个候选" }
            else { return nil }
            return CleanupScanIssue(kind: .limit, path: url.path, message: "扫描达到\(reason)上限；结果仅覆盖已读取的文件。")
        }
        for issue in policy.discoveryIssues { report(issue, isBlocked: issue.kind == .permission || issue.kind == .io) }
        let protection = CleanupRunningProtection(runningBundleIDs: runningBundleIDs, roots: policy.roots)
        // Specific roots are read before wider roots so overlapping cache scopes are
        // attributed once and retain the more precise category.
        var rootPaths: Set<String> = []
        var roots = policy.roots.sorted { $0.url.path.count > $1.url.path.count }
            .filter { rootPaths.insert($0.url.path).inserted }
        let candidateRootCount = roots.count
        var queuedPaths: Set<String> = []
        func postpone(_ root: CleanupRoot, owner: String?, reason: CleanupRetainedReason = .runningApplication) {
            guard queuedPaths.insert(root.url.path).inserted else { return }
            roots.append(root); retainedPartialPaths.insert(root.url.path)
            retain(reason, root: root, owner: owner, bytes: 0, count: 0)
        }
        var rootIndex = 0
        while rootIndex < roots.count {
            let root = roots[rootIndex]
            let statisticsOnly = rootIndex >= candidateRootCount
            rootIndex += 1
            if isExcluded(root.url.path) { continue }
            if let issue = reachedLimit(at: root.url) {
                report(statisticsOnly ? CleanupScanIssue(kind: issue.kind, path: issue.path, message: "运行中缓存占用仅统计了部分：" + issue.message) : issue)
                break
            }
            var rootMetadata = stat()
            if lstat(root.url.path, &rootMetadata) != 0 {
                if errno != ENOENT && errno != ENOTDIR { report(.reading(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), at: root.url), isBlocked: true) }
                continue
            }
            do {
                try CleanupPaths.notProtected(root.url)
                try CleanupPaths.noSymlinks(root.url)
            } catch {
                report(.reading(error, at: root.url), isBlocked: true)
                continue
            }
            guard rootMetadata.st_mode & S_IFMT == S_IFDIR else { continue }
            if excludedIdentities.contains(Identity(device: rootMetadata.st_dev, inode: UInt64(rootMetadata.st_ino))) { continue }
            let rootOwner = protection.runningOwner(for: root.url)
            if !statisticsOnly, root.inventoryOnly || rootOwner != nil {
                postpone(root, owner: rootOwner, reason: rootOwner == nil ? .unknownOwner : .runningApplication)
                completedRoots.insert(root.url.path); continue
            }
            guard seenDirectories.insert(Identity(device: rootMetadata.st_dev, inode: UInt64(rootMetadata.st_ino))).inserted else { continue }
            if let owner = protection.runningOwner(for: root.url) { runningDirectories[root.url.path] = owner }
            let previousBlocked = blocked
            let cutoff = Date().addingTimeInterval(-Double(max(0, root.minimumAgeDays)) * 86400)
            guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [], errorHandler: { url, error in
                report(.reading(error, at: url), isBlocked: true)
                return true
            }) else {
                report(.reading(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)), at: root.url), isBlocked: true)
                continue
            }
            while let file = enumerator.nextObject() as? URL {
                if let issue = reachedLimit(at: root.url) {
                    report(statisticsOnly ? CleanupScanIssue(kind: issue.kind, path: issue.path, message: "运行中缓存占用仅统计了部分：" + issue.message) : issue)
                    break
                }
                let path = CleanupPaths.normalized(file).path
                var metadata = stat()
                guard lstat(file.path, &metadata) == 0 else {
                    report(.reading(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), at: file), isBlocked: true); continue
                }
                let kind = metadata.st_mode & S_IFMT
                if isExcluded(path) || completedRoots.contains(path) {
                    if kind == S_IFDIR { enumerator.skipDescendants() }
                    continue
                }
                guard visitedPaths.insert(path).inserted else {
                    if kind == S_IFDIR { enumerator.skipDescendants() }
                    continue
                }
                visited += 1
                if visited.isMultiple(of: 256) { await Task.yield() }
                let relative = String(path.dropFirst(root.url.path.count + 1))
                let components = relative.lowercased().split(separator: "/").map(String.init)
                if (CleanupPaths.excludedName(file.lastPathComponent) && !Self.databaseName(file.lastPathComponent))
                    || components.contains(where: CleanupPaths.excludedComponent) {
                    if kind == S_IFDIR { enumerator.skipDescendants() }
                    continue
                }
                if excludedIdentities.contains(Identity(device: metadata.st_dev, inode: UInt64(metadata.st_ino))) {
                    if kind == S_IFDIR { enumerator.skipDescendants() }
                    continue
                }
                if kind == S_IFLNK { continue }
                let owner = runningDirectories[(path as NSString).deletingLastPathComponent]
                    ?? protection.runningOwner(component: file.lastPathComponent)
                let protected = protectedDirectories.contains(root.url.path)
                    || components.contains(where: Self.personalDataComponent) || Self.databaseName(file.lastPathComponent)
                if kind == S_IFDIR {
                    if !root.recursive { enumerator.skipDescendants(); continue }
                    if !statisticsOnly && protected {
                        protectedDirectories.insert(path)
                        postpone(CleanupRoot(url: file, category: root.category, minimumAgeDays: root.minimumAgeDays,
                            label: root.label, runningBundleID: owner, inventoryOnly: true), owner: owner, reason: .protectedData)
                        completedRoots.insert(path); enumerator.skipDescendants(); continue
                    }
                    if !statisticsOnly, let owner {
                        postpone(CleanupRoot(url: file, category: root.category, minimumAgeDays: root.minimumAgeDays,
                            label: root.label, runningBundleID: owner), owner: owner)
                        completedRoots.insert(path); enumerator.skipDescendants(); continue
                    }
                    if let owner { runningDirectories[path] = owner }
                    if !seenDirectories.insert(Identity(device: metadata.st_dev, inode: UInt64(metadata.st_ino))).inserted { enumerator.skipDescendants() }
                    continue
                }
                guard kind == S_IFREG else { continue }
                if let extensions = root.allowedExtensions, !extensions.contains(file.pathExtension.lowercased()) { continue }
                guard seenFiles.insert(Identity(device: metadata.st_dev, inode: UInt64(metadata.st_ino))).inserted else { continue }
                scanned += 1
                scannedBytes += max(0, metadata.st_size)
                let stamp = FileFingerprint(metadata)
                let reason: CleanupRetainedReason? = metadata.st_nlink != 1 ? .hardLink
                    : protected ? .protectedData
                    : owner != nil ? .runningApplication
                    : root.inventoryOnly || statisticsOnly ? .unknownOwner
                    : root.minimumAgeDays > 0 && stamp.modifiedAt >= cutoff ? .recent : nil
                metadataFiles.append(CleanupScannedFile(url: CleanupPaths.normalized(file), rootURL: root.url,
                    category: root.category, bytes: max(0, metadata.st_size), device: metadata.st_dev,
                    inode: UInt64(metadata.st_ino), retainedReason: reason))
                guard metadata.st_size > 0 else { continue }
                if let reason { retain(reason, root: root, owner: reason == .runningApplication ? owner : nil, bytes: metadata.st_size); continue }
                let item = CleanupItem(url: CleanupPaths.normalized(file), category: root.category, bytes: stamp.size, modifiedAt: stamp.modifiedAt, fingerprint: stamp)
                items.append(item)
                let top = relative.split(separator: "/").first.map(String.init) ?? root.url.lastPathComponent
                let groupName = root.label ?? (relative.contains("/") ? top : root.url.lastPathComponent + " · 散落文件")
                let groupID = root.category.rawValue + "|" + (root.label ?? root.url.path + "|" + (relative.contains("/") ? top : ".files"))
                groupLabels[groupID] = (groupName, root.category)
                groupItems[groupID, default: []].append(item)
            }
            completedRoots.insert(root.url.path)
            if let issue = reachedLimit(at: root.url) {
                retainedPartialPaths.insert(root.url.path)
                report(statisticsOnly ? CleanupScanIssue(kind: issue.kind, path: issue.path, message: "运行中缓存占用仅统计了部分：" + issue.message) : issue)
                break
            }
            if previousBlocked != blocked { retainedPartialPaths.insert(root.url.path) }
            else if statisticsOnly { retainedPartialPaths.remove(root.url.path) }
        }
        let groups = groupItems.compactMap { id, values -> CleanupGroup? in
            guard let (name, category) = groupLabels[id] else { return nil }
            return CleanupGroup(id: id, name: name, category: category, items: values.sorted { $0.bytes > $1.bytes })
        }.sorted { $0.bytes > $1.bytes }
        let retained = retainedTotals.compactMap { key, total -> CleanupRetainedSummary? in
            guard let info = retainedInfo[key] else { return nil }
            let isPartial = retainedPartialPaths.contains(info.root.url.path)
            if total.count == 0 && !isPartial { return nil }
            return CleanupRetainedSummary(reason: info.reason, category: info.root.category, rootURL: info.root.url,
                ownerBundleID: info.owner, count: total.count, bytes: total.bytes, isPartial: isPartial)
        }.sorted { $0.bytes > $1.bytes }
        return CleanupScan(items: items.sorted { $0.bytes > $1.bytes }, warnings: warnings,
                           scannedFiles: scanned, isPartial: partial, scannedBytes: scannedBytes,
                           groups: groups, blockedCount: blocked, issues: issues, retained: retained, visitedEntries: visited,
                           metadataFiles: metadataFiles)
    }

    private static func databaseName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["db", "sqlite", "sqlite3", "binarycookies"].contains((lower as NSString).pathExtension)
            || lower.hasSuffix("-journal") || lower.hasSuffix("-wal") || lower.hasSuffix("-shm")
    }

    private static func personalDataComponent(_ name: String) -> Bool {
        ["cookies", "history", "login data", "service worker", "local storage", "session storage", "indexeddb",
         "chat", "chats", "conversations", "messages", "attachments", "media"].contains(name)
    }
}

public enum TrashState: String, Codable, Sendable {
    case pending, trashed, restoring, restored, failed
}

public struct TrashRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let originalURL: URL
    public var trashedURL: URL?
    public let bytes: Int64
    public var trashedAt: Date
    public var restoredAt: Date?
    public var state: TrashState
    public var message: String?
    public let scopeRoot: URL
    fileprivate let fingerprint: FileFingerprint
    fileprivate var trashedFingerprint: FileFingerprint?
    fileprivate let recoveryDirectory: URL?
}

public struct TrashFailure: Sendable {
    public let url: URL
    public let message: String
}

public struct TrashBatch: Sendable {
    public let records: [TrashRecord]
    public let failures: [TrashFailure]
    public var totalBytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
}

public enum CleanupError: LocalizedError {
    case unauthorized(String), symlink(String), fileChanged(String), unsupported(String)
    case unavailable(String), corruptHistory, conflict(String), journal(String), missingRecord

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let path): return "此路径不在允许的清理范围内：\(path)"
        case .symlink(let path): return "跳过符号链接路径：\(path)"
        case .fileChanged(let path): return "文件已在扫描后变化，请重新扫描：\(path)"
        case .unsupported(let path): return "不支持清理此类型：\(path)"
        case .unavailable(let path): return "文件不存在或无法读取：\(path)"
        case .corruptHistory: return "清理历史损坏或版本不受支持；已停止操作以保留恢复记录。"
        case .conflict(let path): return "原位置已有文件，无法覆盖恢复：\(path)"
        case .journal(let message): return "无法保存恢复记录；操作已停止：\(message)"
        case .missingRecord: return "未找到可恢复的清理记录。"
        }
    }
}

public actor TrashStore {
    public static var defaultHistoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit/cleanup-history.json")
    }

    private let historyURL: URL
    private let allowedRoots: [URL]
    private let quarantineURL: URL?
    private let fm = FileManager.default

    /// quarantineURL is an isolated test destination. Production uses macOS Trash.
    public init(historyURL: URL = TrashStore.defaultHistoryURL,
                allowedRoots: [URL] = CleanupPolicy.production().writableRoots.map(\.url),
                quarantineURL: URL? = nil) {
        self.historyURL = CleanupPaths.normalized(historyURL)
        self.allowedRoots = allowedRoots.map(CleanupPaths.normalized)
        self.quarantineURL = quarantineURL.map(CleanupPaths.normalized)
    }

    public func history() throws -> [TrashRecord] {
        try locked {
            var journal = try load()
            if try reconcile(&journal) { try save(journal) }
            return journal.records.sorted { $0.trashedAt > $1.trashedAt }
        }
    }

    public func moveToTrash(_ items: [CleanupItem]) throws -> TrashBatch {
        try locked {
            var journal = try load()
            if try reconcile(&journal) { try save(journal) }
            var failures: [TrashFailure] = []
            var prepared: [(item: CleanupItem, record: TrashRecord, index: Int)] = []
            var unique: Set<String> = []
            for item in items where unique.insert(item.id).inserted {
                do {
                    let root = try admittedRoot(item.url)
                    try verify(item)
                    let id = UUID()
                    let recovery: URL?
                    if let quarantineURL {
                        try createSafeDirectory(quarantineURL)
                        recovery = quarantineURL
                    } else {
                        recovery = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: item.url, create: false)
                    }
                    let destination = quarantineURL?.appendingPathComponent(id.uuidString + "-" + item.name)
                    let record = TrashRecord(id: id, originalURL: item.url, trashedURL: destination, bytes: item.bytes,
                                             trashedAt: Date(), restoredAt: nil, state: .pending, message: nil,
                                             scopeRoot: root, fingerprint: item.fingerprint, trashedFingerprint: nil,
                                             recoveryDirectory: recovery)
                    prepared.append((item, record, journal.records.count + prepared.count))
                } catch { failures.append(TrashFailure(url: item.url, message: error.localizedDescription)) }
            }
            guard !prepared.isEmpty else { return TrashBatch(records: [], failures: failures) }
            journal.records.append(contentsOf: prepared.map { $0.record })
            try save(journal) // Persist every intent before moving any file.
            var successes: [TrashRecord] = []
            for (item, intent, index) in prepared {
                do {
                    _ = try admittedRoot(item.url)
                    try verify(item)
                    let destination: URL
                    if let quarantineURL {
                        try CleanupPaths.noSymlinks(quarantineURL)
                        destination = intent.trashedURL!
                        try fm.moveItem(at: item.url, to: destination)
                    } else {
                        var actual: NSURL?
                        try fm.trashItem(at: item.url, resultingItemURL: &actual)
                        guard let actual else { throw CleanupError.unavailable("macOS 未返回废纸篓位置") }
                        destination = actual as URL
                    }
                    journal.records[index].trashedURL = destination
                    journal.records[index].trashedFingerprint = try? CleanupPaths.fingerprint(destination)
                    journal.records[index].trashedAt = Date()
                    journal.records[index].state = .trashed
                    successes.append(journal.records[index])
                } catch {
                    // A missing source may mean macOS moved it before returning an error.
                    // Retain the intent for recovery rather than mislabeling it as untouched.
                    journal.records[index].state = fm.fileExists(atPath: item.url.path) ? .failed : .pending
                    journal.records[index].message = error.localizedDescription
                    failures.append(TrashFailure(url: item.url, message: error.localizedDescription))
                }
            }
            // If this write fails, the durable intents are reconciled by inode on the next read.
            try save(journal)
            return TrashBatch(records: successes, failures: failures)
        }
    }

    public func restore(_ recordID: UUID) throws {
        try locked {
            var journal = try load()
            if try reconcile(&journal) { try save(journal) }
            guard let index = journal.records.firstIndex(where: { $0.id == recordID }),
                  journal.records[index].state == .trashed,
                  let source = journal.records[index].trashedURL else { throw CleanupError.missingRecord }
            let record = journal.records[index]
            try CleanupPaths.notProtected(record.originalURL)
            guard CleanupPaths.descendant(record.originalURL, of: record.scopeRoot), record.scopeRoot.path != "/" else {
                throw CleanupError.unauthorized(record.originalURL.path)
            }
            try CleanupPaths.noSymlinks(record.originalURL, allowMissingTail: true)
            if fm.fileExists(atPath: record.originalURL.path) { throw CleanupError.conflict(record.originalURL.path) }
            try CleanupPaths.noSymlinks(source)
            if let stamp = record.trashedFingerprint { try verify(source, expected: stamp, protect: false) }
            try createSafeDirectory(record.originalURL.deletingLastPathComponent())
            journal.records[index].state = .restoring
            try save(journal)
            do {
                try CleanupPaths.noSymlinks(record.originalURL, allowMissingTail: true)
                try fm.moveItem(at: source, to: record.originalURL)
            } catch {
                journal.records[index].state = .trashed
                journal.records[index].message = error.localizedDescription
                try save(journal)
                throw error
            }
            journal.records[index].state = .restored
            journal.records[index].restoredAt = Date()
            journal.records[index].message = nil
            try save(journal)
        }
    }

    private struct Journal: Codable {
        var version: Int = 1
        var records: [TrashRecord] = []
    }

    private func admittedRoot(_ url: URL) throws -> URL {
        try CleanupPaths.notProtected(url)
        guard let root = allowedRoots.first(where: { $0.path != "/" && CleanupPaths.descendant(url, of: $0) }) else {
            throw CleanupError.unauthorized(url.path)
        }
        try CleanupPaths.noSymlinks(url)
        return root
    }

    private func verify(_ item: CleanupItem) throws {
        try verify(item.url, expected: item.fingerprint)
        if let contents = item.contents, try BuildOutputs.stamp(item.url) != contents { throw CleanupError.fileChanged(item.url.path) }
    }

    private func verify(_ url: URL, expected: FileFingerprint, protect: Bool = true) throws {
        if protect { try CleanupPaths.notProtected(url) }
        try CleanupPaths.noSymlinks(url)
        guard try CleanupPaths.fingerprint(url) == expected else { throw CleanupError.fileChanged(url.path) }
    }

    private func createSafeDirectory(_ url: URL) throws {
        try CleanupPaths.noSymlinks(url, allowMissingTail: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try CleanupPaths.noSymlinks(url)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try createSafeDirectory(historyURL.deletingLastPathComponent())
        let path = historyURL.path + ".lock"
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CleanupError.journal(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CleanupError.journal("无法锁定历史文件") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func load() throws -> Journal {
        try CleanupPaths.noSymlinks(historyURL, allowMissingTail: true)
        guard fm.fileExists(atPath: historyURL.path) else { return Journal() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let journal = try decoder.decode(Journal.self, from: Data(contentsOf: historyURL))
            guard journal.version == 1 else { throw CleanupError.corruptHistory }
            return journal
        } catch { throw CleanupError.corruptHistory }
    }

    private func save(_ journal: Journal) throws {
        do {
            try CleanupPaths.noSymlinks(historyURL, allowMissingTail: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(journal).write(to: historyURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch { throw CleanupError.journal(error.localizedDescription) }
    }

    private func reconcile(_ journal: inout Journal) throws -> Bool {
        var changed = false
        for index in journal.records.indices {
            let record = journal.records[index]
            if record.state == .restoring,
               let current = try? CleanupPaths.fingerprint(record.originalURL),
               let expected = record.trashedFingerprint,
               current.device == expected.device, current.inode == expected.inode,
               current.size == expected.size,
               record.trashedURL.map({ !fm.fileExists(atPath: $0.path) }) == true {
                journal.records[index].state = .restored
                journal.records[index].restoredAt = Date()
                changed = true
            } else if record.state == .restoring,
                      !fm.fileExists(atPath: record.originalURL.path),
                      let source = record.trashedURL,
                      let expected = record.trashedFingerprint,
                      let current = try? CleanupPaths.fingerprint(source), current == expected {
                try CleanupPaths.noSymlinks(source)
                journal.records[index].state = .trashed
                journal.records[index].message = "上次恢复已中断，文件仍在废纸篓，可重试恢复。"
                changed = true
            } else if record.state == .pending {
                var found = record.trashedURL.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
                if found == nil, !fm.fileExists(atPath: record.originalURL.path), let directory = record.recoveryDirectory {
                    try CleanupPaths.noSymlinks(directory)
                    found = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { candidate in
                        guard let stamp = try? CleanupPaths.fingerprint(candidate) else { return false }
                        return stamp.device == record.fingerprint.device && stamp.inode == record.fingerprint.inode
                    }
                }
                if let found {
                    journal.records[index].trashedURL = found
                    journal.records[index].trashedFingerprint = try? CleanupPaths.fingerprint(found)
                    journal.records[index].state = .trashed
                } else {
                    journal.records[index].state = .failed
                    journal.records[index].message = fm.fileExists(atPath: record.originalURL.path)
                        ? "上次操作中断，原文件仍在。"
                        : "上次操作中断，需在废纸篓核对原文件；不会自动再次清理。"
                }
                changed = true
            }
        }
        return changed
    }
}

enum CleanupPaths {
    // Foundation's standardizedFileURL rewrites /private/var to the /var symlink on macOS.
    // Normalize only lexical path components so noSymlinks can inspect the actual path.
    static func normalized(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        var components: [Substring] = []
        for part in url.path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else { components.append(part) }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
    }

    static func descendant(_ url: URL, of root: URL) -> Bool {
        let path = normalized(url).path
        let base = normalized(root).path
        return path != base && path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func fingerprint(_ url: URL) throws -> FileFingerprint {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CleanupError.unavailable(url.path) }
        guard value.st_mode & S_IFMT != S_IFLNK else { throw CleanupError.symlink(url.path) }
        return FileFingerprint(value)
    }

    static func noSymlinks(_ url: URL, allowMissingTail: Bool = false) throws {
        guard url.isFileURL else { throw CleanupError.unauthorized(url.absoluteString) }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in normalized(url).pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var value = stat()
            if lstat(current.path, &value) != 0 {
                if allowMissingTail && errno == ENOENT { return }
                throw CleanupError.unavailable(current.path)
            }
            if value.st_mode & S_IFMT == S_IFLNK { throw CleanupError.symlink(current.path) }
        }
    }

    static func excludedComponent(_ name: String) -> Bool {
        let name = name.lowercased()
        return [".git", ".codex", ".claude", ".agents", ".ssh", ".gnupg", "keychains", "com.orbitmac.orbit", "orbit", "orbit.app"].contains(name)
    }

    static func excludedName(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["agents.md", "claude.md", "memory.md", "skill.md"].contains(name)
            || name.hasSuffix(".lock") || name == "lock" || name == "singletonlock"
            || name.hasSuffix(".db-wal") || name.hasSuffix(".db-shm") || name.hasSuffix(".sqlite-wal")
    }

    static func notProtected(_ url: URL) throws {
        let path = normalized(url).path
        let protected = ["/System", "/bin", "/sbin", "/usr", "/Library", "/private/etc", "/private/var/db", "/private/var/root"]
        let blockedRoot = ["/", "/Users", "/home", FileManager.default.homeDirectoryForCurrentUser.path]
        let pieces = url.pathComponents.map { $0.lowercased() }
        if blockedRoot.contains(path) || protected.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
            || pieces.contains(where: excludedComponent) || excludedName(url.lastPathComponent) {
            throw CleanupError.unauthorized(path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let personal = ["Library/Mail", "Library/Messages", "Library/Accounts", "Library/Application Support/Orbit", ".config", ".local/share"]
        for suffix in personal {
            let root = home.appendingPathComponent(suffix)
            if path == root.path || descendant(url, of: root) { throw CleanupError.unauthorized(path) }
        }
    }
}
