import Foundation
import Darwin

public enum ExtendedCleanupSection: String, Codable, CaseIterable, Sendable {
    case systemData, trash
}

public enum ExtendedCleanupHandling: String, Codable, Sendable {
    case administratorReview, permanentRemovalReview
}

public enum ExtendedCleanupAccess: String, Codable, Sendable {
    case readable, missing, denied, partial, unsupported, duplicate
}

public struct ExtendedCleanupRoot: Hashable, Sendable {
    public let url: URL
    public let title: String

    public init(url: URL, title: String) {
        self.url = CleanupPaths.normalized(url); self.title = title
    }
}

public struct ExtendedMetadataFile: Sendable {
    public let url: URL
    public let device: UInt64
    public let inode: UInt64
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let isHardLinked: Bool
}

/// This inventory has no deletion API and does not produce ordinary CleanupItems.
public struct ExtendedCleanupEntry: Identifiable, Sendable {
    public var id: String { section.rawValue + "|" + url.path }
    public let url: URL
    public let rootURL: URL
    public let title: String
    public let section: ExtendedCleanupSection
    public var handling: ExtendedCleanupHandling { section == .trash ? .permanentRemovalReview : .administratorReview }
    public let logicalBytes: Int64?
    public let allocatedBytes: Int64?
    public let fileCount: Int
    public let hardLinkBytes: Int64
    public let symbolicLinkCount: Int
    public let files: [ExtendedMetadataFile]
    public let access: ExtendedCleanupAccess
    public let issues: [CleanupScanIssue]
    public var isPartial: Bool { [.denied, .partial, .unsupported].contains(access) }
}

public struct ExtendedCleanupScan: Sendable {
    public let items: [ExtendedCleanupEntry]
    public let visitedEntries: Int
    public let issues: [CleanupScanIssue]
    public var files: [ExtendedMetadataFile] { items.flatMap(\.files) }
    public var isPartial: Bool { items.contains(where: \.isPartial) }
    public var systemBytes: Int64 { items.filter { $0.section == .systemData }.reduce(0) { $0 + ($1.logicalBytes ?? 0) } }
    public var trashBytes: Int64 { items.filter { $0.section == .trash }.reduce(0) { $0 + ($1.logicalBytes ?? 0) } }
}

public struct ExtendedCleanupPolicy: Sendable {
    public let systemRoots: [ExtendedCleanupRoot]
    public let trashRoots: [URL]
    public let maximumEntries: Int
    public let maximumTrashItems: Int
    public let timeLimit: TimeInterval

    public init(systemRoots: [ExtendedCleanupRoot], trashRoots: [URL], maximumEntries: Int = 300_000,
                maximumTrashItems: Int = 10_000, timeLimit: TimeInterval = 30) {
        var paths: Set<String> = []
        self.systemRoots = systemRoots.filter { paths.insert($0.url.path).inserted }
        paths = []
        self.trashRoots = trashRoots.map(CleanupPaths.normalized).filter { paths.insert($0.path).inserted }
        self.maximumEntries = max(0, maximumEntries)
        self.maximumTrashItems = max(0, maximumTrashItems)
        self.timeLimit = max(0, timeLimit)
    }

    public static func production(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  mountedVolumes: [URL]? = nil, userID: uid_t = getuid()) -> ExtendedCleanupPolicy {
        let volumes = mountedVolumes ?? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey]) ?? []
        var trash = [home.appendingPathComponent(".Trash")]
        for volume in volumes where volume.path.hasPrefix("/Volumes/") {
            if (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
                trash.append(volume.appendingPathComponent(".Trashes/\(userID)"))
            }
        }
        return ExtendedCleanupPolicy(systemRoots: [
            ExtendedCleanupRoot(url: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches"), title: "模拟器系统缓存"),
            ExtendedCleanupRoot(url: URL(fileURLWithPath: "/Library/Caches"), title: "系统缓存"),
            ExtendedCleanupRoot(url: URL(fileURLWithPath: "/private/var/log"), title: "系统日志"),
            ExtendedCleanupRoot(url: URL(fileURLWithPath: "/private/var/db/diagnostics"), title: "系统诊断日志"),
            ExtendedCleanupRoot(url: URL(fileURLWithPath: "/private/var/db/uuidtext"), title: "系统诊断辅助数据")
        ], trashRoots: trash)
    }
}

public struct ExtendedCleanupScanner: Sendable {
    public let policy: ExtendedCleanupPolicy
    private let directoryContents: (@Sendable (URL) throws -> [URL])?

    public init(policy: ExtendedCleanupPolicy = .production()) {
        self.policy = policy
        directoryContents = nil
    }

    init(policy: ExtendedCleanupPolicy, directoryContents: @escaping @Sendable (URL) throws -> [URL]) {
        self.policy = policy; self.directoryContents = directoryContents
    }

    public func scan() async -> ExtendedCleanupScan {
        let start = ProcessInfo.processInfo.systemUptime
        var visited = 0
        var discovered = 0
        var seenFiles: Set<Identity> = []
        var seenDirectories: Set<Identity> = []
        var seenPaths: Set<String> = []
        var entries: [ExtendedCleanupEntry] = []
        var allIssues: [CleanupScanIssue] = []

        func contents(_ url: URL, maximum: Int? = nil) throws -> (entries: [URL], truncated: Bool) {
            let remaining = min(maximum ?? policy.maximumEntries, max(0, policy.maximumEntries - discovered))
            let value: (entries: [URL], truncated: Bool)
            if let directoryContents {
                let all = try directoryContents(url)
                value = (Array(all.prefix(remaining)), all.count > remaining)
            } else {
                value = try Self.boundedDirectoryEntries(url, maximum: remaining, deadline: start + policy.timeLimit)
            }
            discovered += value.entries.count
            return value
        }

        func discoveryIssue(at url: URL) -> CleanupScanIssue {
            if Task.isCancelled { return CleanupScanIssue(kind: .cancelled, path: url.path, message: "目录发现已取消，显示已统计部分") }
            return CleanupScanIssue(kind: .limit, path: url.path, message: "目录发现达到条目或时间预算，未列出的内容占用未知")
        }

        func stopped(at url: URL) -> CleanupScanIssue? {
            if Task.isCancelled { return CleanupScanIssue(kind: .cancelled, path: url.path, message: "扫描已取消，显示已统计部分") }
            if visited >= policy.maximumEntries {
                return CleanupScanIssue(kind: .limit, path: url.path, message: "达到 \(policy.maximumEntries) 条路径预算，显示已统计部分")
            }
            if ProcessInfo.processInfo.systemUptime - start >= policy.timeLimit {
                return CleanupScanIssue(kind: .limit, path: url.path, message: "达到扫描时间预算，显示已统计部分")
            }
            return nil
        }

        func append(_ url: URL, root: URL, title: String, section: ExtendedCleanupSection,
                    bytes: Int64?, allocated: Int64?, files: Int = 0, hardLinks: Int64 = 0, links: Int = 0,
                    metadataFiles: [ExtendedMetadataFile] = [], access: ExtendedCleanupAccess, issues: [CleanupScanIssue] = []) {
            let value = ExtendedCleanupEntry(url: url, rootURL: root, title: title, section: section,
                logicalBytes: bytes, allocatedBytes: allocated, fileCount: files, hardLinkBytes: hardLinks,
                symbolicLinkCount: links, files: metadataFiles, access: access, issues: issues)
            entries.append(value); allIssues.append(contentsOf: issues)
        }

        func unavailable(_ url: URL, root: URL, title: String, section: ExtendedCleanupSection, error: Error) {
            let issue = CleanupScanIssue.reading(error, at: url)
            append(url, root: root, title: title, section: section, bytes: nil, allocated: nil,
                access: issue.kind == .permission ? .denied : .partial, issues: [issue])
        }

        for section in ExtendedCleanupSection.allCases {
            let roots: [(URL, String)] = section == .systemData
                ? policy.systemRoots.map { ($0.url, $0.title) }
                : policy.trashRoots.map { ($0, $0.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path ? "废纸篓" : "废纸篓 · " + $0.path) }
            for (root, rootTitle) in roots {
                guard root.isFileURL else {
                    append(root, root: root, title: rootTitle, section: section, bytes: nil, allocated: nil, access: .unsupported,
                        issues: [CleanupScanIssue(kind: .io, path: root.absoluteString, message: "仅支持本地文件路径")])
                    continue
                }
                if let issue = stopped(at: root) {
                    append(root, root: root, title: rootTitle, section: section, bytes: nil, allocated: nil, access: .partial, issues: [issue]); continue
                }
                do { try Self.noAncestorLinks(root) }
                catch let error as InventoryPathError {
                    switch error {
                    case .missing:
                        append(root, root: root, title: rootTitle, section: section, bytes: nil, allocated: nil, access: .missing)
                    case .symbolicLink:
                        append(root, root: root, title: rootTitle, section: section, bytes: nil, allocated: nil, access: .unsupported,
                            issues: [CleanupScanIssue(kind: .io, path: root.path, message: "路径含符号链接，保留且未沿链接读取")])
                    }
                    continue
                } catch { unavailable(root, root: root, title: rootTitle, section: section, error: error); continue }

                var top = [root]
                var topIssues: [CleanupScanIssue] = []
                if section == .trash {
                    do {
                        let listing = try contents(root, maximum: policy.maximumTrashItems)
                        top = listing.entries.sorted { $0.path < $1.path }
                        if listing.truncated { topIssues.append(discoveryIssue(at: root)) }
                    }
                    catch { unavailable(root, root: root, title: rootTitle, section: section, error: error); continue }
                    if top.isEmpty {
                        append(root, root: root, title: rootTitle, section: section, bytes: topIssues.isEmpty ? 0 : nil,
                            allocated: topIssues.isEmpty ? 0 : nil, access: topIssues.isEmpty ? .readable : .partial, issues: topIssues)
                        continue
                    }
                }

                for source in top {
                    let title = section == .trash ? source.lastPathComponent : rootTitle
                    var bytes: Int64 = 0, allocated: Int64 = 0, hardLinks: Int64 = 0
                    var files = 0, links = 0, measured = false, duplicate = false
                    var metadataFiles: [ExtendedMetadataFile] = []
                    var issues: [CleanupScanIssue] = []
                    var pending = [source]
                    while let current = pending.popLast() {
                        if let issue = stopped(at: current) { issues.append(issue); break }
                        guard seenPaths.insert(current.path).inserted else { duplicate = true; continue }
                        visited += 1
                        if visited.isMultiple(of: 256) { await Task.yield() }
                        var metadata = stat()
                        guard lstat(current.path, &metadata) == 0 else {
                            issues.append(.reading(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), at: current)); continue
                        }
                        let kind = metadata.st_mode & S_IFMT
                        let identity = Identity(device: metadata.st_dev, inode: metadata.st_ino)
                        if kind == S_IFDIR {
                            guard seenDirectories.insert(identity).inserted else { duplicate = true; continue }
                            do {
                                let listing = try contents(current)
                                let children = listing.entries.sorted { $0.path > $1.path }
                                measured = true
                                pending.append(contentsOf: children)
                                if listing.truncated { issues.append(discoveryIssue(at: current)) }
                            } catch { issues.append(.reading(error, at: current)) }
                        } else if kind == S_IFREG || kind == S_IFLNK {
                            guard seenFiles.insert(identity).inserted else { duplicate = true; continue }
                            measured = true
                            bytes += max(0, metadata.st_size)
                            allocated += max(0, Int64(metadata.st_blocks)) * 512
                            if kind == S_IFLNK { links += 1 }
                            else {
                                files += 1
                                if metadata.st_nlink > 1 { hardLinks += max(0, metadata.st_size) }
                                metadataFiles.append(ExtendedMetadataFile(url: current,
                                    device: UInt64(bitPattern: Int64(metadata.st_dev)), inode: UInt64(metadata.st_ino),
                                    logicalBytes: max(0, metadata.st_size), allocatedBytes: max(0, Int64(metadata.st_blocks)) * 512,
                                    isHardLinked: metadata.st_nlink > 1))
                            }
                        } else if current == source {
                            issues.append(CleanupScanIssue(kind: .io, path: current.path, message: "特殊文件仅保留，不计为可处理缓存"))
                        }
                    }
                    let access: ExtendedCleanupAccess
                    if !issues.isEmpty { access = !measured && issues.allSatisfy { $0.kind == .permission } ? .denied : .partial }
                    else { access = !measured && duplicate ? .duplicate : .readable }
                    let hasSize = (measured || access == .duplicate) && (issues.isEmpty || bytes > 0 || allocated > 0)
                    append(source, root: root, title: title, section: section,
                        bytes: hasSize ? bytes : nil, allocated: hasSize ? allocated : nil,
                        files: files, hardLinks: hardLinks, links: links, metadataFiles: metadataFiles, access: access, issues: issues)
                }
                if !topIssues.isEmpty {
                    append(root, root: root, title: rootTitle + "（未统计部分）", section: section,
                        bytes: nil, allocated: nil, access: .partial, issues: topIssues)
                }
            }
        }
        return ExtendedCleanupScan(items: entries, visitedEntries: visited, issues: allIssues)
    }

    private struct Identity: Hashable { let device: dev_t; let inode: ino_t }
    private enum InventoryPathError: Error { case missing, symbolicLink }

    static func boundedDirectoryEntries(_ directory: URL, maximum: Int, deadline: TimeInterval) throws -> (entries: [URL], truncated: Bool) {
        guard maximum > 0 else { return ([], true) }
        let fd = open(directory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard let stream = fdopendir(fd) else { let code = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        defer { closedir(stream) }
        var entries: [URL] = []
        while true {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { return (entries, true) }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                return (entries, false)
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name != "." && name != ".." else { continue }
            if entries.count >= maximum { return (entries, true) }
            entries.append(directory.appendingPathComponent(name))
        }
    }

    private static func noAncestorLinks(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR { throw InventoryPathError.missing }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            if metadata.st_mode & S_IFMT == S_IFLNK { throw InventoryPathError.symbolicLink }
        }
    }
}
