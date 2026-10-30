import Foundation
import Darwin

public struct CleanupScannedFile: Sendable {
    public let url: URL
    public let rootURL: URL
    public let category: CleanupCategory
    public let bytes: Int64
    public let device: Int32
    public let inode: UInt64
    public let retainedReason: CleanupRetainedReason?
}

public enum CleanupScanIssueKind: String, Codable, CaseIterable, Sendable {
    case permission, io, limit, cancelled
}

public struct CleanupScanIssue: Identifiable, Codable, Hashable, Sendable {
    public let kind: CleanupScanIssueKind
    public let path: String
    public let errorDomain: String?
    public let errorCode: Int?
    public let underlyingPOSIXCode: Int?
    public let message: String
    public var id: String { "\(kind.rawValue)|\(path)|\(errorDomain ?? "")|\(errorCode ?? 0)|\(message)" }

    public init(kind: CleanupScanIssueKind, path: String, errorDomain: String? = nil, errorCode: Int? = nil,
                underlyingPOSIXCode: Int? = nil, message: String) {
        self.kind = kind; self.path = path; self.errorDomain = errorDomain; self.errorCode = errorCode
        self.underlyingPOSIXCode = underlyingPOSIXCode; self.message = message
    }

    static func reading(_ error: Error, at url: URL) -> CleanupScanIssue {
        let native = error as NSError
        var current: NSError? = native
        var posix: Int?
        for _ in 0..<8 {
            guard let value = current else { break }
            if value.domain == NSPOSIXErrorDomain { posix = value.code; break }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let denied = posix == Int(EPERM) || posix == Int(EACCES)
            || (native.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(native.code))
        return CleanupScanIssue(kind: denied ? .permission : .io, path: url.path,
            errorDomain: native.domain, errorCode: native.code, underlyingPOSIXCode: posix,
            message: "无法读取：\(url.path)（\(native.localizedDescription)）")
    }
}

public enum CleanupRetainedReason: String, Codable, CaseIterable, Sendable {
    case runningApplication, recent, hardLink, unknownOwner, protectedData
}

public struct CleanupRetainedSummary: Identifiable, Sendable {
    public let reason: CleanupRetainedReason
    public let category: CleanupCategory
    public let rootURL: URL
    public let ownerBundleID: String?
    public let count: Int
    public let bytes: Int64
    public let isPartial: Bool
    public var id: String { "\(reason.rawValue)|\(category.rawValue)|\(rootURL.path)|\(ownerBundleID ?? "")" }

    public init(reason: CleanupRetainedReason, category: CleanupCategory, rootURL: URL,
                ownerBundleID: String? = nil, count: Int, bytes: Int64, isPartial: Bool = false) {
        self.reason = reason; self.category = category; self.rootURL = rootURL
        self.ownerBundleID = ownerBundleID; self.count = count; self.bytes = bytes
        self.isPartial = isPartial
    }
}

/// Construct once from fresh process state before scanning or executing a selection.
public struct CleanupRunningProtection: Sendable {
    private let aliases: [String: String]
    private let prefixAliases: [(prefix: String, suffix: String, nested: String, owner: String)]
    private let ownedRoots: [(path: String, owner: String)]

    static let knownAliases: [String: [String]] = [
        "com.electron.lark": ["Lark", "LarkShell", "Feishu", "com.bytedance.macos.feishu"],
        "com.anthropic.claudefordesktop": ["Claude"],
        "com.openai.codex": ["Codex"],
        "com.openai.chat": ["ChatGPT"],
        "com.tencent.xinwechat": ["WeChat", "Weixin", "com.tencent.WeChat"],
        "com.todesktop.230313mzl4w4u92": ["Cursor", "com.anysphere.cursor", "com.anysphere.sand"],
        "com.google.chrome": ["Google Chrome", "Chrome"],
        "com.microsoft.edgemac": ["Microsoft Edge", "Edge"],
        "md.obsidian": ["obsidian"],
        "com.tencent.qqmusicmac": ["QQMusic"],
    ]

    public init(runningBundleIDs: Set<String>, roots: [CleanupRoot]) {
        var names: [String: String] = [:]
        for identifier in runningBundleIDs.sorted() {
            let lower = identifier.lowercased()
            names[lower] = identifier
            if let short = lower.split(separator: ".").last, short.count >= 4 { names[String(short)] = identifier }
        }
        for (canonical, values) in Self.knownAliases.sorted(by: { $0.key < $1.key }) {
            let family = [canonical] + values.map { $0.lowercased() }
            if let owner = runningBundleIDs.sorted().first(where: { id in
                family.contains { id.lowercased() == $0 || id.lowercased().hasPrefix($0 + ".") }
            }) {
                for alias in family { names[alias] = owner }
            }
        }
        aliases = names
        prefixAliases = names.map { (prefix: $0.key + ".", suffix: "." + $0.key, nested: "." + $0.key + ".", owner: $0.value) }
            .sorted { $0.prefix.count > $1.prefix.count }
        ownedRoots = roots.compactMap { root in
            guard let owner = root.runningBundleID.flatMap({ names[$0.lowercased()] }) else { return nil }
            return (root.url.path, owner)
        }.sorted { $0.path.count > $1.path.count }
    }

    public func runningOwner(for url: URL) -> String? {
        let path = CleanupPaths.normalized(url).path
        if let root = ownedRoots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { return root.owner }
        for component in url.pathComponents.reversed() { if let owner = runningOwner(component: component) { return owner } }
        return nil
    }

    func runningOwner(component: String) -> String? {
        let lower = component.lowercased()
        if let owner = aliases[lower] { return owner }
        guard lower.contains(".") else { return nil }
        return prefixAliases.first { lower.hasPrefix($0.prefix) || lower.hasSuffix($0.suffix) || lower.contains($0.nested) }?.owner
    }

    public func protects(_ url: URL) -> Bool { runningOwner(for: url) != nil }
}

/// Discovery reads directory entries and installed bundle metadata, never user document bodies.
enum CleanupScopeDiscovery {
    static func children(_ directory: URL, issues: inout [CleanupScanIssue], reportBrowserProfileLinks: Bool = false,
                         includeRegularFiles: Bool = false) -> [URL] {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno != ENOENT && errno != ENOTDIR { issues.append(.reading(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), at: directory)) }
            return []
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            if info.st_mode & S_IFMT == S_IFLNK { issues.append(.reading(CleanupError.symlink(directory.path), at: directory)) }
            return []
        }
        do {
            try CleanupPaths.noSymlinks(directory)
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
            if entries.count > 10_000 {
                issues.append(CleanupScanIssue(kind: .limit, path: directory.path, message: "目录发现达到 10000 项上限：\(directory.path)"))
            }
            return entries.prefix(10_000).filter { url in
                var st = stat()
                if lstat(url.path, &st) != 0 {
                    issues.append(.reading(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), at: url)); return false
                }
                let name = url.lastPathComponent
                let profile = name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst(8)) != nil)
                if reportBrowserProfileLinks, profile, st.st_mode & S_IFMT == S_IFLNK { issues.append(.reading(CleanupError.symlink(url.path), at: url)) }
                return st.st_mode & S_IFMT == S_IFDIR || (includeRegularFiles && st.st_mode & S_IFMT == S_IFREG)
            }
        } catch { issues.append(.reading(error, at: directory)); return [] }
    }

    static func installedApplications(home: URL, issues: inout [CleanupScanIssue]) -> [String: Set<String>] {
        var applications: [String: Set<String>] = [:]
        var pending = [(home.appendingPathComponent("Applications"), 0)]
        if home.path == FileManager.default.homeDirectoryForCurrentUser.path { pending.append((URL(fileURLWithPath: "/Applications"), 0)) }
        while let (directory, depth) = pending.popLast() {
            for app in children(directory, issues: &issues) {
                if app.pathExtension.lowercased() != "app" {
                    if depth < 2 { pending.append((app, depth + 1)) }
                    continue
                }
                let info = app.appendingPathComponent("Contents/Info.plist")
                do {
                    try CleanupPaths.noSymlinks(info)
                    let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
                    guard let plist = value as? [String: Any], let identifier = plist["CFBundleIdentifier"] as? String else { continue }
                    var names = Set([identifier, app.deletingPathExtension().lastPathComponent])
                    for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                        if let name = plist[key] as? String { names.insert(name) }
                    }
                    applications[identifier, default: []].formUnion(names)
                } catch { issues.append(.reading(error, at: info)) }
            }
        }
        return applications
    }
}
