import Foundation
import CryptoKit
import Darwin

public enum AIPackageKind: String, Codable, Sendable { case npm, homebrewFormula, homebrewCask }
public enum AIPackageActivity {
    public static func runningTools() -> Set<AITool> {
        var tools = AIActivity.runningTools()
        // AIActivity marks both Pi and Cursor when a generic Node runtime is present.
        // Such a runtime can also be an older npm Codex/Claude CLI; retain all npm tools.
        if tools.contains(.pi) && tools.contains(.cursor) { tools.formUnion([.codex, .claude]) }
        return tools
    }
}
public struct AIPackageLocations: Codable, Sendable {
    public let npmPrefixes: [URL]
    public let homebrewPrefixes: [URL]
    public init(npmPrefixes: [URL], homebrewPrefixes: [URL]) {
        self.npmPrefixes = npmPrefixes; self.homebrewPrefixes = homebrewPrefixes
    }
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        var prefixes = [home.appendingPathComponent(".local"), home.appendingPathComponent(".npm-global"), URL(fileURLWithPath: "/usr/local"), URL(fileURLWithPath: "/opt/homebrew")]
        for entry in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let bin = URL(fileURLWithPath: String(entry))
            if bin.lastPathComponent == "bin" { prefixes.append(bin.deletingLastPathComponent()) }
        }
        let versions = home.appendingPathComponent(".nvm/versions/node")
        if let children = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) { prefixes += children.prefix(30) }
        var seen = Set<String>()
        return Self(npmPrefixes: prefixes.filter { seen.insert($0.path).inserted }, homebrewPrefixes: [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")])
    }
}
public struct AIPackageCandidate: Identifiable, Codable, Sendable {
    public var id: String { kind.rawValue + ":" + packageURL.path }
    public let tool: AITool
    public let kind: AIPackageKind
    public let name: String
    public let version: String
    public let prefix: URL
    public let packageURL: URL
    public let paths: [URL]
    public let bytes: Int64
    public let dependencies: [String]
    public let referencedBy: [String]
    /// Program distribution mtime only; it is not evidence that a tool is idle.
    public let modifiedAt: Date
    public let fingerprints: [String: String]
    public let linkTargets: [String: String]
}
public struct AIPackageRetention: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let reason: String
}
public struct AIPackageScan: Sendable {
    public let candidates: [AIPackageCandidate]
    public let retained: [AIPackageRetention]
    public let warnings: [String]
    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}
public enum AIPackageError: LocalizedError {
    case unsafe(String), changed, busy, conflict(String), corruptHistory, budget
    public var errorDescription: String? {
        switch self {
        case .unsafe(let reason): return "程序包已保留：" + reason
        case .changed: return "程序包、链接或依赖已改变，请重新扫描。"
        case .busy: return "检测到可能使用程序包的进程，或另一项卸载/恢复正在进行。"
        case .conflict(let path): return "原位置已有文件，未覆盖：" + path
        case .corruptHistory: return "程序包恢复记录不可读，已停止操作。"
        case .budget: return "程序包检查达到预算，未确认部分全部保留。"
        }
    }
}

private enum PackageRegistry {
    static let npm: [String: AITool] = ["@openai/codex": .codex, "@anthropic-ai/claude-code": .claude,
        "@mariozechner/pi-coding-agent": .pi, "@earendil-works/pi-coding-agent": .pi]
    static let brew: [String: AITool] = ["codex": .codex, "claude-code": .claude, "ollama": .ollama]
    static func bins(_ tool: AITool) -> Set<String> {
        switch tool { case .codex: return ["codex"]; case .claude: return ["claude"]; case .pi: return ["pi"]; case .ollama: return ["ollama"]; case .cursor: return [] }
    }
}

public actor AIPackageScanner {
    private let home: URL
    private let locations: AIPackageLocations
    private let activity: AIActivityProvider
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, locations: AIPackageLocations? = nil,
                activity: @escaping AIActivityProvider = { AIPackageActivity.runningTools() }) {
        self.home = home; self.locations = locations ?? .standard(home: home); self.activity = activity
    }
    public func scan(activeTools: Set<AITool> = []) async -> AIPackageScan {
        var candidates: [AIPackageCandidate] = [], retained: [AIPackageRetention] = [], warnings: [String] = []
        let running = activeTools.union(activity())
        func keep(_ url: URL, _ name: String, _ reason: String) {
            if retained.count < 300 { retained.append(AIPackageRetention(url: url, name: name, reason: reason)) }
        }
        for prefix in locations.npmPrefixes where PackageFiles.exists(prefix.appendingPathComponent("lib/node_modules")) {
            do {
                let inventory = try PackageInventory.npm(prefix)
                for entry in inventory.entries where PackageRegistry.npm[entry.name] != nil {
                    do {
                        let tool = PackageRegistry.npm[entry.name]!
                        guard !running.contains(tool) else { throw AIPackageError.busy }
                        guard inventory.complete else { throw AIPackageError.unsafe("全局 npm 依赖清单不完整。") }
                        let refs = inventory.entries.filter { $0.url != entry.url && $0.dependencies.contains(entry.name) }.map(\.name)
                        guard refs.isEmpty else { throw AIPackageError.unsafe("仍被其他全局包引用：" + refs.joined(separator: "、")) }
                        let bins = try PackageFiles.npmBins(entry.manifest)
                        guard !bins.isEmpty, Set(bins.keys).isSubset(of: PackageRegistry.bins(tool)) else { throw AIPackageError.unsafe("CLI 映射不受支持。") }
                        for (bin, target) in bins {
                            let destination = try PackageFiles.relative(target, under: entry.url)
                            let link = prefix.appendingPathComponent("bin/" + bin)
                            guard try PackageFiles.linkDestination(link) == destination.path else { throw AIPackageError.unsafe("CLI 链接归属无法确认：" + link.path) }
                        }
                        let links = try PackageFiles.ownedLinks(prefix: prefix, package: entry.url, roots: ["bin", "share/man"])
                        candidates.append(try PackageFiles.candidate(tool: tool, kind: .npm, entry: entry, prefix: prefix, links: links, home: home))
                    } catch { keep(entry.url, entry.name, error.localizedDescription) }
                }
                if !inventory.complete { warnings.append("npm 清单不完整：" + prefix.path) }
            } catch { warnings.append(error.localizedDescription) }
        }
        for prefix in locations.homebrewPrefixes where PackageFiles.exists(prefix.appendingPathComponent("Cellar")) || PackageFiles.exists(prefix.appendingPathComponent("Caskroom")) {
            do {
                let inventory = try PackageInventory.brew(prefix)
                for entry in inventory.entries where PackageRegistry.brew[entry.name] != nil {
                    do {
                        let tool = PackageRegistry.brew[entry.name]!
                        guard !running.contains(tool) else { throw AIPackageError.busy }
                        guard inventory.complete else { throw AIPackageError.unsafe("其他已装 Homebrew 包的收据或依赖 schema 不完整。") }
                        let refs = inventory.entries.filter { $0.url != entry.url && $0.dependencies.contains(where: { $0.split(separator: "/").last.map(String.init) == entry.name }) }.map(\.name)
                        guard refs.isEmpty else { throw AIPackageError.unsafe("仍被已装包引用：" + refs.joined(separator: "、")) }
                        guard entry.tap == (entry.kind == .homebrewCask ? "homebrew/cask" : "homebrew/core") else { throw AIPackageError.unsafe("不是已确认的官方 Homebrew 收据。") }
                        guard !PackageFiles.exists(prefix.appendingPathComponent("var/homebrew/pinned/" + entry.name)) else { throw AIPackageError.unsafe("此包已固定版本。") }
                        for base in [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")] {
                            if PackageFiles.exists(base.appendingPathComponent("homebrew.mxcl." + entry.name + ".plist")) { throw AIPackageError.unsafe("仍有后台服务配置，先在启动项中核对。") }
                        }
                        if entry.kind == .homebrewCask { try PackageFiles.validateCask(entry, prefix: prefix, tool: tool) }
                        else {
                            for keg in try PackageFiles.children(entry.url) {
                                let library = keg.appendingPathComponent("lib")
                                if PackageFiles.exists(library), !(try PackageFiles.children(library)).isEmpty {
                                    throw AIPackageError.unsafe("程序包导出库文件，动态依赖尚不能完整闭合。")
                                }
                            }
                        }
                        let links = try PackageFiles.ownedLinks(prefix: prefix, package: entry.url, roots: ["bin", "sbin", "opt", "share", "lib", "include", "var/homebrew/linked"])
                        guard links.keys.contains(where: { PackageRegistry.bins(tool).contains(URL(fileURLWithPath: $0).lastPathComponent) && URL(fileURLWithPath: $0).deletingLastPathComponent().path == prefix.appendingPathComponent("bin").path }) else { throw AIPackageError.unsafe("未确认独立 CLI 链接。") }
                        candidates.append(try PackageFiles.candidate(tool: tool, kind: entry.kind, entry: entry, prefix: prefix, links: links, home: home))
                    } catch { keep(entry.url, entry.name, error.localizedDescription) }
                }
                if !inventory.complete { warnings.append("Homebrew 收据覆盖不完整：" + prefix.path) }
            } catch { warnings.append(error.localizedDescription) }
        }
        return AIPackageScan(candidates: candidates.sorted { $0.packageURL.path < $1.packageURL.path }, retained: retained, warnings: Array(warnings.prefix(20)))
    }
}

private struct PackageEntry {
    let name: String
    let version: String
    let url: URL
    let kind: AIPackageKind
    let dependencies: [String]
    let manifest: [String: Any]
    let tap: String?
    let hasUninstallHooks: Bool
}
private struct PackageInventory {
    var entries: [PackageEntry] = []
    var complete = true
    static func npm(_ prefix: URL) throws -> Self {
        let root = prefix.appendingPathComponent("lib/node_modules")
        var paths: [URL] = [], result = Self()
        for url in try PackageFiles.children(root) where !url.lastPathComponent.hasPrefix(".") {
            if url.lastPathComponent.hasPrefix("@") { paths += try PackageFiles.children(url) }
            else { paths.append(url) }
        }
        guard paths.count <= 2000 else { throw AIPackageError.budget }
        for path in paths {
            do {
                let manifest = try PackageFiles.json(path.appendingPathComponent("package.json"))
                guard let name = manifest["name"] as? String, let version = manifest["version"] as? String,
                      !version.isEmpty, path.path == root.appendingPathComponent(name).path else { throw AIPackageError.changed }
                var dependencies = Set<String>()
                for key in ["dependencies", "optionalDependencies", "peerDependencies"] {
                    if let value = manifest[key] {
                        guard let values = value as? [String: String] else { throw AIPackageError.changed }
                        dependencies.formUnion(values.keys)
                    }
                }
                result.entries.append(PackageEntry(name: name, version: version, url: path, kind: .npm, dependencies: dependencies.sorted(), manifest: manifest, tap: nil, hasUninstallHooks: false))
            } catch {
                result.complete = false
                // Keep a visible official package even if its manifest cannot be trusted.
                let relative = String(path.path.dropFirst(root.path.count + 1))
                if PackageRegistry.npm[relative] != nil { result.entries.append(PackageEntry(name: relative, version: "未知", url: path, kind: .npm, dependencies: [], manifest: [:], tap: nil, hasUninstallHooks: false)) }
            }
        }
        return result
    }
    static func brew(_ prefix: URL) throws -> Self {
        var result = Self()
        let cellar = prefix.appendingPathComponent("Cellar")
        if PackageFiles.exists(cellar) {
            for rack in try PackageFiles.children(cellar) where !rack.lastPathComponent.hasPrefix(".") {
                do {
                    let kegs = try PackageFiles.children(rack)
                    guard !kegs.isEmpty, kegs.count < 50 else { throw AIPackageError.changed }
                    var deps = Set<String>(), versions: [String] = [], tap: String?
                    for keg in kegs {
                        let receipt = try PackageFiles.json(keg.appendingPathComponent("INSTALL_RECEIPT.json"))
                        guard let runtime = receipt["runtime_dependencies"] as? [[String: Any]], let source = receipt["source"] as? [String: Any], let currentTap = source["tap"] as? String else { throw AIPackageError.changed }
                        if let tap, tap != currentTap { throw AIPackageError.changed }
                        tap = currentTap
                        for item in runtime { guard let name = item["full_name"] as? String else { throw AIPackageError.changed }; deps.insert(name) }
                        versions.append(keg.lastPathComponent)
                    }
                    result.entries.append(PackageEntry(name: rack.lastPathComponent, version: versions.sorted().joined(separator: ", "), url: rack, kind: .homebrewFormula, dependencies: deps.sorted(), manifest: [:], tap: tap, hasUninstallHooks: false))
                } catch { result.complete = false; result.appendUnknown(rack, kind: .homebrewFormula) }
            }
        }
        let caskroom = prefix.appendingPathComponent("Caskroom")
        if PackageFiles.exists(caskroom) {
            for rack in try PackageFiles.children(caskroom) where !rack.lastPathComponent.hasPrefix(".") {
                do {
                    let receipt = try PackageFiles.json(rack.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
                    guard let runtime = receipt["runtime_dependencies"] as? [String: Any], let source = receipt["source"] as? [String: Any],
                          let tap = source["tap"] as? String, let version = source["version"] as? String else { throw AIPackageError.changed }
                    var dependencies = Set<String>()
                    guard Set(runtime.keys).isSubset(of: ["formula", "cask"]) else { throw AIPackageError.changed }
                    for value in runtime.values { guard let values = value as? [[String: Any]] else { throw AIPackageError.changed }; for item in values { guard let name = item["full_name"] as? String else { throw AIPackageError.changed }; dependencies.insert(name) } }
                    let metadata = rack.appendingPathComponent(".metadata")
                    let manifests = try PackageFiles.descendants(metadata, maximum: 2000).filter { $0.lastPathComponent == rack.lastPathComponent + ".json" && $0.deletingLastPathComponent().lastPathComponent == "Casks" }
                    guard manifests.count == 1 else { throw AIPackageError.changed }
                    let manifest = try PackageFiles.json(manifests[0])
                    guard manifest["token"] as? String == rack.lastPathComponent, manifest["version"] as? String == version else { throw AIPackageError.changed }
                    let hooks = (receipt["uninstall_flight_blocks"] as? Bool) != false || !(receipt["uninstall_artifacts"] as? [Any] ?? [NSNull()]).isEmpty
                    result.entries.append(PackageEntry(name: rack.lastPathComponent, version: version, url: rack, kind: .homebrewCask, dependencies: dependencies.sorted(), manifest: manifest, tap: tap, hasUninstallHooks: hooks))
                } catch { result.complete = false; result.appendUnknown(rack, kind: .homebrewCask) }
            }
        }
        guard result.entries.count < 2000 else { throw AIPackageError.budget }
        return result
    }
    mutating func appendUnknown(_ url: URL, kind: AIPackageKind) {
        if PackageRegistry.brew[url.lastPathComponent] != nil { entries.append(PackageEntry(name: url.lastPathComponent, version: "未知", url: url, kind: kind, dependencies: [], manifest: [:], tap: nil, hasUninstallHooks: true)) }
    }
}

public enum AIPackageMoveState: String, Codable, Sendable { case pending, moved, restoring, restored }
public struct AIPackageFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let owner: UInt32
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    fileprivate init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino
        mode = UInt32(value.st_mode); owner = value.st_uid; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }
}
public struct AIPackageMove: Codable, Sendable {
    public let originalURL: URL
    public let storedURL: URL
    public let fingerprint: String
    public var state: AIPackageMoveState
    public var recoveryLocation: URL? = nil
    public var recoveryFingerprint: String? = nil
    public var recoveryIdentity: AIPackageFileIdentity? = nil
}
public struct AIPackageRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let candidate: AIPackageCandidate
    public let createdAt: Date
    public var moves: [AIPackageMove]
    public var message: String
    public var isRestored: Bool { !moves.isEmpty && moves.allSatisfy { $0.state == .restored } }
}

/// Program files are retained intact. No npm/brew uninstall hook, zap, config or dependency deletion runs.
public actor AIPackageStore {
    private let home: URL
    private let locations: AIPackageLocations
    private let recoveryRoot: URL
    private let activity: AIActivityProvider
    private let beforeRename: (@Sendable (URL, URL) throws -> Void)?
    private var inFlight = false
    private var journal: URL { recoveryRoot.appendingPathComponent("history.json") }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, locations: AIPackageLocations? = nil,
                recoveryRoot: URL? = nil, activity: @escaping AIActivityProvider = { AIPackageActivity.runningTools() }) {
        self.home = home; self.locations = locations ?? .standard(home: home)
        self.recoveryRoot = recoveryRoot ?? home.appendingPathComponent("Library/Application Support/Orbit/AIPackageRecovery")
        self.activity = activity
        beforeRename = nil
    }
    init(home: URL, locations: AIPackageLocations, recoveryRoot: URL? = nil,
         activity: @escaping AIActivityProvider, beforeRename: @escaping @Sendable (URL, URL) throws -> Void) {
        self.home = home; self.locations = locations
        self.recoveryRoot = recoveryRoot ?? home.appendingPathComponent("Library/Application Support/Orbit/AIPackageRecovery")
        self.activity = activity; self.beforeRename = beforeRename
    }
    public func remove(_ candidate: AIPackageCandidate, activeTools: Set<AITool> = []) async throws -> AIPackageRecord {
        guard !inFlight else { throw AIPackageError.busy }; inFlight = true; defer { inFlight = false }
        try setup()
        let lock = try acquireLock(); defer { flock(lock, LOCK_UN); close(lock) }
        var records = try load()
        let managerLease = try PackageManagerLease(candidate: candidate, home: home)
        defer { managerLease.close() }
        let scan = await AIPackageScanner(home: home, locations: locations, activity: activity).scan(activeTools: activeTools)
        guard let fresh = scan.candidates.first(where: { $0.id == candidate.id }),
              fresh.fingerprints == candidate.fingerprints, fresh.linkTargets == candidate.linkTargets,
              fresh.version == candidate.version else { throw AIPackageError.changed }
        let id = UUID()
        let directory = recoveryRoot.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Links first disables the CLI; the complete package directory moves last.
        let ordered = fresh.paths.filter { $0 != fresh.packageURL } + [fresh.packageURL]
        var record = AIPackageRecord(id: id, candidate: fresh, createdAt: Date(), moves: ordered.enumerated().map {
            AIPackageMove(originalURL: $0.element, storedURL: directory.appendingPathComponent(String($0.offset)), fingerprint: fresh.fingerprints[$0.element.path]!, state: .pending)
        }, message: "准备移走程序包；配置与共享依赖保留。")
        records.append(record); try save(records)
        do {
            for index in record.moves.indices {
                try Task.checkCancellation()
                try managerLease.check()
                guard !activity().union(activeTools).contains(candidate.tool) else { throw AIPackageError.busy }
                let move = record.moves[index]
                do {
                    try PackageFiles.renameExclusive(move.originalURL, move.storedURL, expected: move.fingerprint,
                        logicalPackage: candidate.packageURL, logicalURL: move.originalURL, beforeRename: beforeRename)
                } catch let relocation as PackageRelocationFailure {
                    record.moves[index].state = .moved
                    record.moves[index].recoveryLocation = relocation.location
                    record.moves[index].recoveryFingerprint = relocation.signature
                    record.moves[index].recoveryIdentity = relocation.identity
                    record.message = "路径在操作期间变化；内容保留在：" + relocation.location.path
                    records[records.count - 1] = record; try save(records)
                    throw AIPackageError.unsafe(record.message)
                }
                record.moves[index].state = .moved
                records[records.count - 1] = record; try save(records)
            }
            record.message = "程序包和已确认的链接已移到恢复目录；配置、会话、记忆、技能与共享依赖保留。"
            records[records.count - 1] = record; try save(records)
            return record
        } catch {
            record.message = "未全部完成：" + error.localizedDescription
            records[records.count - 1] = record; try? save(records)
            throw error
        }
    }
    public func history() throws -> [AIPackageRecord] { try load().reversed() }
    public func restore(_ id: UUID, activeTools: Set<AITool> = []) async throws {
        guard !inFlight else { throw AIPackageError.busy }; inFlight = true; defer { inFlight = false }
        try setup()
        let lock = try acquireLock(); defer { flock(lock, LOCK_UN); close(lock) }
        var records = try load()
        guard let recordIndex = records.firstIndex(where: { $0.id == id }) else { throw AIPackageError.corruptHistory }
        let candidate = records[recordIndex].candidate
        try validate(candidate)
        let managerLease = try PackageManagerLease(candidate: candidate, home: home)
        defer { managerLease.close() }
        guard !activity().union(activeTools).contains(candidate.tool) else { throw AIPackageError.busy }
        for index in records[recordIndex].moves.indices.reversed() {
            try managerLease.check()
            var move = records[recordIndex].moves[index]
            if move.state == .restored { continue }
            guard candidate.paths.contains(move.originalURL), move.storedURL.deletingLastPathComponent().deletingLastPathComponent().path == recoveryRoot.path,
                  move.storedURL.deletingLastPathComponent().lastPathComponent == id.uuidString,
                  move.storedURL.lastPathComponent == String(index),
                  move.fingerprint == candidate.fingerprints[move.originalURL.path] else { throw AIPackageError.corruptHistory }
            let original = PackageFiles.exists(move.originalURL), stored = PackageFiles.exists(move.storedURL)
            if let location = move.recoveryLocation {
                guard location.path == move.storedURL.path, move.recoveryFingerprint != nil else {
                    throw AIPackageError.unsafe("路径发生并发变化，内容完整保留待核对：" + location.path)
                }
            }
            let expected = move.recoveryFingerprint ?? move.fingerprint
            if original && !stored && (move.state == .pending || move.state == .restoring) {
                guard try PackageFiles.fingerprint(move.originalURL, logicalPackage: candidate.packageURL).signature == expected else { throw AIPackageError.changed }
                move.state = .restored; records[recordIndex].moves[index] = move; try save(records); continue
            }
            guard !original else { throw AIPackageError.conflict(move.originalURL.path) }
            guard stored, try PackageFiles.fingerprint(move.storedURL, logicalPackage: candidate.packageURL, logicalURL: move.originalURL).signature == expected else { throw AIPackageError.changed }
            if move.originalURL != candidate.packageURL {
                guard let target = candidate.linkTargets[move.originalURL.path],
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: move.storedURL.path)) == target else { throw AIPackageError.corruptHistory }
            }
            guard !activity().union(activeTools).contains(candidate.tool) else { throw AIPackageError.busy }
            move.state = .restoring; records[recordIndex].moves[index] = move; try save(records)
            do {
                try PackageFiles.renameExclusive(move.storedURL, move.originalURL, expected: expected,
                    logicalPackage: candidate.packageURL, logicalURL: move.originalURL, beforeRename: beforeRename)
            } catch let relocation as PackageRelocationFailure {
                move.recoveryLocation = relocation.location; move.recoveryFingerprint = relocation.signature
                move.recoveryIdentity = relocation.identity
                records[recordIndex].moves[index] = move
                records[recordIndex].message = "恢复时路径改变，内容完整保留待核对：" + relocation.location.path
                try save(records); throw AIPackageError.unsafe(records[recordIndex].message)
            }
            move.state = .restored; records[recordIndex].moves[index] = move; try save(records)
        }
    }
    private func validate(_ candidate: AIPackageCandidate) throws {
        let prefixes = candidate.kind == .npm ? locations.npmPrefixes : locations.homebrewPrefixes
        guard prefixes.contains(where: { $0.path == candidate.prefix.path }),
              candidate.kind == .npm ? PackageRegistry.npm[candidate.name] == candidate.tool : PackageRegistry.brew[candidate.name] == candidate.tool,
              candidate.packageURL.path == candidate.prefix.appendingPathComponent(candidate.kind == .npm ? "lib/node_modules/" + candidate.name : (candidate.kind == .homebrewFormula ? "Cellar/" : "Caskroom/") + candidate.name).path,
              Set(candidate.paths.map(\.path)) == Set([candidate.packageURL.path] + Array(candidate.linkTargets.keys)) else { throw AIPackageError.corruptHistory }
        for path in candidate.linkTargets.keys {
            let allowed = (candidate.kind == .npm ? ["bin/", "share/man/"] : ["bin/", "sbin/", "opt/", "share/", "lib/", "include/", "var/homebrew/linked/"])
            guard allowed.contains(where: { path.hasPrefix(candidate.prefix.path + "/" + $0) }), !path.hasPrefix(candidate.packageURL.path + "/") else { throw AIPackageError.corruptHistory }
        }
    }
    private func setup() throws {
        try PackageFiles.noLinks(recoveryRoot, missingAllowed: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryRoot.path)
        guard try PackageFiles.device(recoveryRoot) == PackageFiles.device(home) else { throw AIPackageError.unsafe("恢复目录不在同一磁盘。") }
    }
    private func acquireLock() throws -> Int32 {
        let fd = open(recoveryRoot.appendingPathComponent("mutation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AIPackageError.busy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw AIPackageError.busy }
        return fd
    }
    private func load() throws -> [AIPackageRecord] {
        guard PackageFiles.exists(journal) else { return [] }
        try PackageFiles.noLinks(journal)
        let data = try Data(contentsOf: journal)
        guard data.count < 20_000_000, let records = try? JSONDecoder().decode([AIPackageRecord].self, from: data) else { throw AIPackageError.corruptHistory }
        return records
    }
    private func save(_ records: [AIPackageRecord]) throws {
        try PackageFiles.noLinks(journal, missingAllowed: true)
        try JSONEncoder().encode(records).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let fd = open(journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AIPackageError.corruptHistory }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw AIPackageError.corruptHistory }
    }
}

private struct PackageDigest {
    let signature: String
    let bytes: Int64
    let modified: Date
    let identity: AIPackageFileIdentity
}
private struct PackageRelocationFailure: Error {
    let location: URL
    let identity: AIPackageFileIdentity?
    let signature: String?
}
private final class PackagePinnedParent {
    let url: URL
    let fd: Int32
    let identity: AIPackageFileIdentity
    init(_ url: URL) throws {
        guard url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw AIPackageError.changed }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw AIPackageError.changed }
        do {
            for component in url.pathComponents where component != "/" {
                guard component != ".", !component.utf8.contains(0) else { throw AIPackageError.changed }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AIPackageError.changed }
                close(current); current = next
            }
            var st = stat(); guard fstat(current, &st) == 0 else { throw AIPackageError.changed }
            self.url = url; fd = current; identity = AIPackageFileIdentity(st)
        } catch { close(current); throw error }
    }
    deinit { close(fd) }
    func remainsMapped() -> Bool {
        guard let reopened = try? PackagePinnedParent(url) else { return false }
        return reopened.identity.device == identity.device && reopened.identity.inode == identity.inode
            && reopened.identity.mode == identity.mode && reopened.identity.owner == identity.owner
    }
    func actualURL(for name: String) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(fd, F_GETPATH, &buffer) == 0 { return URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent(name) }
        return url.appendingPathComponent(name)
    }
}

/// Cooperates with an existing Homebrew lock without creating or deleting manager files.
/// npm's hidden package-lock is an index, not a running lock; only legacy _locks/.staging block.
private final class PackageManagerLease {
    private let candidate: AIPackageCandidate
    private let home: URL
    private var fd: Int32 = -1
    private var parent: PackagePinnedParent?
    private var identity: AIPackageFileIdentity?
    private var name: String?
    init(candidate: AIPackageCandidate, home: URL) throws {
        self.candidate = candidate; self.home = home
        if candidate.kind != .npm {
            let suffix = candidate.kind == .homebrewCask ? "cask" : "formula"
            let file = candidate.prefix.appendingPathComponent("var/homebrew/locks/\(candidate.name).\(suffix).lock")
            if PackageFiles.exists(file) {
                let pinned = try PackagePinnedParent(file.deletingLastPathComponent())
                let opened = openat(pinned.fd, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard opened >= 0 else { throw AIPackageError.busy }
                var st = stat()
                guard fstat(opened, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                      st.st_uid == getuid(), st.st_nlink == 1, flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                    Darwin.close(opened); throw AIPackageError.busy
                }
                fd = opened; parent = pinned; identity = AIPackageFileIdentity(st); name = file.lastPathComponent
            }
        }
        do { try check() } catch { close(); throw error }
    }
    deinit { close() }
    func check() throws {
        if candidate.kind == .npm {
            for directory in [home.appendingPathComponent(".npm/_locks"), candidate.prefix.appendingPathComponent("lib/node_modules/.staging")] where PackageFiles.exists(directory) {
                guard (try PackageFiles.children(directory)).isEmpty else { throw AIPackageError.busy }
            }
        }
        if let parent, let name, let identity {
            var current = stat()
            guard parent.remainsMapped(), fstatat(parent.fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  AIPackageFileIdentity(current) == identity else { throw AIPackageError.busy }
        }
    }
    func close() { if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
}

private enum PackageFiles {
    static func exists(_ url: URL) -> Bool { var st = stat(); return lstat(url.path, &st) == 0 }
    static func device(_ url: URL) throws -> dev_t { var st = stat(); guard lstat(url.path, &st) == 0 else { throw AIPackageError.changed }; return st.st_dev }
    static func noLinks(_ url: URL, missingAllowed: Bool = false) throws {
        guard url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw AIPackageError.changed }
        var cursor = url
        while cursor.path != "/" {
            var st = stat()
            if lstat(cursor.path, &st) != 0 {
                if missingAllowed && errno == ENOENT { cursor.deleteLastPathComponent(); continue }
                throw AIPackageError.changed
            }
            guard st.st_mode & S_IFMT != S_IFLNK else { throw AIPackageError.unsafe("存在符号链接祖先：" + cursor.path) }
            cursor.deleteLastPathComponent()
        }
    }
    static func children(_ url: URL) throws -> [URL] {
        try noLinks(url)
        let result = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard result.count <= 5000 else { throw AIPackageError.budget }; return result
    }
    static func descendants(_ url: URL, maximum: Int) throws -> [URL] {
        var result: [URL] = [], pending = [url]
        while let next = pending.popLast() {
            for child in try children(next) {
                guard result.count < maximum, !Task.isCancelled else { throw AIPackageError.budget }
                result.append(child)
                var st = stat(); guard lstat(child.path, &st) == 0 else { throw AIPackageError.changed }
                if st.st_mode & S_IFMT == S_IFDIR { pending.append(child) }
            }
        }
        return result
    }
    static func json(_ url: URL) throws -> [String: Any] {
        try noLinks(url)
        var st = stat(); guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size < 4_000_000 else { throw AIPackageError.changed }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AIPackageError.changed }; defer { close(fd) }
        var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_ino == st.st_ino, opened.st_dev == st.st_dev else { throw AIPackageError.changed }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count,
              let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { throw AIPackageError.changed }; return object
    }
    static func relative(_ path: String, under root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.isEmpty else { throw AIPackageError.changed }
        return root.appendingPathComponent(path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
    }
    static func lexical(_ path: String) -> String {
        var components: [Substring] = []
        for part in path.split(separator: "/") { if part == "." { continue }; if part == ".." { if !components.isEmpty { components.removeLast() } } else { components.append(part) } }
        return "/" + components.joined(separator: "/")
    }
    static func linkDestination(_ url: URL) throws -> String {
        try noLinks(url.deletingLastPathComponent())
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        return lexical(target.hasPrefix("/") ? target : url.deletingLastPathComponent().path + "/" + target)
    }
    static func npmBins(_ manifest: [String: Any]) throws -> [String: String] {
        if let bins = manifest["bin"] as? [String: String] { return bins }
        if let target = manifest["bin"] as? String, let name = manifest["name"] as? String { return [String(name.split(separator: "/").last ?? ""): target] }
        throw AIPackageError.unsafe("缺少可确认的 npm bin 映射。")
    }
    static func ownedLinks(prefix: URL, package: URL, roots: [String]) throws -> [String: String] {
        var result: [String: String] = [:], visited = 0
        for relativeRoot in roots {
            let root = prefix.appendingPathComponent(relativeRoot)
            guard exists(root) else { continue }
            var pending = [root]
            while let directory = pending.popLast() {
                for child in try children(directory) {
                    visited += 1; guard visited < 30_000, !Task.isCancelled else { throw AIPackageError.budget }
                    var st = stat(); guard lstat(child.path, &st) == 0 else { throw AIPackageError.changed }
                    if st.st_mode & S_IFMT == S_IFLNK {
                        let destination = try linkDestination(child)
                        if destination == package.path || destination.hasPrefix(package.path + "/") {
                            guard st.st_uid == getuid(), st.st_nlink == 1, FileManager.default.isWritableFile(atPath: child.deletingLastPathComponent().path) else { throw AIPackageError.unsafe("程序链接不属于当前用户或不可写。") }
                            result[child.path] = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                        }
                    } else if st.st_mode & S_IFMT == S_IFDIR { pending.append(child) }
                }
            }
        }
        return result
    }
    static func validateCask(_ entry: PackageEntry, prefix: URL, tool: AITool) throws {
        guard !entry.hasUninstallHooks else { throw AIPackageError.unsafe("cask 仍有卸载脚本或未知钩子，未移动程序包。") }
        guard let artifacts = entry.manifest["artifacts"] as? [[String: Any]], !artifacts.isEmpty else { throw AIPackageError.unsafe("cask artifact 清单不可确认。") }
        let versions = try children(entry.url).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard versions.count == 1, versions[0].lastPathComponent == entry.version else { throw AIPackageError.unsafe("cask 版本目录不唯一。") }
        var binaries = 0
        for artifact in artifacts {
            if artifact["zap"] != nil { continue } // User data in zap is deliberately retained, never read.
            guard Set(artifact.keys).isSubset(of: ["binary", "target"]), let binary = artifact["binary"] as? [Any], let source = binary.first as? String else { throw AIPackageError.unsafe("cask 含生成文件、安装脚本或其他不可归属 artifact。") }
            let target = artifact["target"] as? String ?? (binary.dropFirst().first as? [String: String])?["target"] ?? URL(fileURLWithPath: source).lastPathComponent
            let name = URL(fileURLWithPath: target).lastPathComponent
            guard PackageRegistry.bins(tool).contains(name), target == name || target == "$HOMEBREW_PREFIX/bin/" + name || target == prefix.appendingPathComponent("bin/" + name).path else { throw AIPackageError.changed }
            let destination = try relative(source, under: versions[0])
            guard try linkDestination(prefix.appendingPathComponent("bin/" + name)) == destination.path else { throw AIPackageError.changed }
            binaries += 1
        }
        guard binaries > 0 else { throw AIPackageError.changed }
    }
    static func candidate(tool: AITool, kind: AIPackageKind, entry: PackageEntry, prefix: URL, links: [String: String], home: URL) throws -> AIPackageCandidate {
        try noLinks(entry.url)
        guard try device(entry.url) == device(home), FileManager.default.isWritableFile(atPath: entry.url.deletingLastPathComponent().path),
              !entry.url.path.hasPrefix("/Volumes/") else { throw AIPackageError.unsafe("程序包不在当前可写磁盘。") }
        var signatures: [String: String] = [:], bytes: Int64 = 0, modified = Date.distantPast
        let paths = links.keys.sorted().map { URL(fileURLWithPath: $0) } + [entry.url]
        for path in paths {
            let stamp = try fingerprint(path, logicalPackage: entry.url)
            signatures[path.path] = stamp.signature; bytes += stamp.bytes; modified = max(modified, stamp.modified)
        }
        return AIPackageCandidate(tool: tool, kind: kind, name: entry.name, version: entry.version, prefix: prefix, packageURL: entry.url,
            paths: paths, bytes: bytes, dependencies: entry.dependencies, referencedBy: [], modifiedAt: modified, fingerprints: signatures, linkTargets: links)
    }
    static func fingerprint(_ url: URL, logicalPackage: URL, logicalURL: URL? = nil) throws -> PackageDigest {
        let parent = try PackagePinnedParent(url.deletingLastPathComponent())
        let digest = try fingerprint(parentFD: parent.fd, name: url.lastPathComponent, logicalPackage: logicalPackage, logicalURL: logicalURL ?? url)
        guard parent.remainsMapped() else { throw AIPackageError.changed }
        return digest
    }
    private static func entryStat(_ parentFD: Int32, _ name: String) throws -> stat {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw AIPackageError.changed }
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw AIPackageError.changed }
        return st
    }
    private static func names(_ directoryFD: Int32) throws -> [String] {
        let duplicate = dup(directoryFD)
        guard duplicate >= 0 else { throw AIPackageError.changed }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw AIPackageError.changed }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw AIPackageError.changed }; break
            }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw AIPackageError.changed }
            if name == "." || name == ".." { continue }
            names.append(name); guard names.count <= 5000 else { throw AIPackageError.budget }
        }
        return names.sorted()
    }
    private static func fingerprint(parentFD: Int32, name: String, logicalPackage: URL, logicalURL: URL) throws -> PackageDigest {
        let original = try entryStat(parentFD, name)
        let rootIdentity = AIPackageFileIdentity(original)
        var hash = SHA256(), total: Int64 = 0, visited = 0, latest = Date.distantPast
        let started = ProcessInfo.processInfo.systemUptime
        func feed(_ parent: Int32, _ leaf: String, _ relative: String) throws {
            visited += 1
            guard visited <= 100_000, ProcessInfo.processInfo.systemUptime - started < 30, !Task.isCancelled else { throw AIPackageError.budget }
            let st = try entryStat(parent, leaf), identity = AIPackageFileIdentity(st)
            guard st.st_uid == getuid(), st.st_dev == original.st_dev else { throw AIPackageError.unsafe("程序文件不属于当前用户或跨越磁盘。") }
            let mode = st.st_mode & S_IFMT
            latest = max(latest, Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9))
            hash.update(data: Data("\(relative)|\(st.st_dev)|\(st.st_ino)|\(st.st_mode)|\(st.st_uid)|\(st.st_size)|\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec)|".utf8))
            if mode == S_IFLNK {
                guard st.st_nlink == 1 else { throw AIPackageError.unsafe("程序含硬链接。") }
                var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
                let count = readlinkat(parent, leaf, &bytes, bytes.count)
                guard count > 0, count < bytes.count, let target = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw AIPackageError.changed }
                let logicalPath = relative.isEmpty ? logicalURL : logicalURL.appendingPathComponent(relative)
                let destination = lexical(target.hasPrefix("/") ? target : logicalPath.deletingLastPathComponent().path + "/" + target)
                guard destination == logicalPackage.path || destination.hasPrefix(logicalPackage.path + "/") else { throw AIPackageError.unsafe("程序含越界链接。") }
                hash.update(data: Data(target.utf8))
            } else if mode == S_IFREG {
                guard st.st_nlink == 1 else { throw AIPackageError.unsafe("程序含硬链接。") }
                let logicalName = relative.isEmpty ? logicalURL.lastPathComponent : leaf
                guard ![".npmrc", ".env", "auth.json", "credentials.json"].contains(logicalName.lowercased()) else { throw AIPackageError.unsafe("程序目录含可能的个人凭据文件，保留整个包。") }
                total += st.st_size; guard total <= 2_000_000_000 else { throw AIPackageError.budget }
                let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw AIPackageError.changed }; defer { close(fd) }
                var before = stat(); guard fstat(fd, &before) == 0, AIPackageFileIdentity(before) == identity else { throw AIPackageError.changed }
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    guard count >= 0 else { throw AIPackageError.changed }
                    if count == 0 { break }
                    guard ProcessInfo.processInfo.systemUptime - started < 30, !Task.isCancelled else { throw AIPackageError.budget }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                var after = stat(); guard fstat(fd, &after) == 0, AIPackageFileIdentity(after) == identity else { throw AIPackageError.changed }
            } else if mode == S_IFDIR {
                let directory = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw AIPackageError.changed }; defer { close(directory) }
                var opened = stat(); guard fstat(directory, &opened) == 0, AIPackageFileIdentity(opened) == identity else { throw AIPackageError.changed }
                for child in try names(directory) { try feed(directory, child, relative.isEmpty ? child : relative + "/" + child) }
            } else { throw AIPackageError.unsafe("程序包含不支持的文件类型。") }
            guard AIPackageFileIdentity(try entryStat(parent, leaf)) == identity else { throw AIPackageError.changed }
        }
        try feed(parentFD, name, "")
        return PackageDigest(signature: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: total, modified: latest, identity: rootIdentity)
    }
    static func renameExclusive(_ source: URL, _ destination: URL, expected: String,
                                logicalPackage: URL, logicalURL: URL,
                                beforeRename: (@Sendable (URL, URL) throws -> Void)?) throws {
        let sourceParent = try PackagePinnedParent(source.deletingLastPathComponent())
        let destinationParent = try PackagePinnedParent(destination.deletingLastPathComponent())
        let digest = try fingerprint(parentFD: sourceParent.fd, name: source.lastPathComponent, logicalPackage: logicalPackage, logicalURL: logicalURL)
        guard digest.signature == expected, digest.identity.device == destinationParent.identity.device else { throw AIPackageError.changed }
        try beforeRename?(source, destination)
        // Re-open every ancestor without following links, then compare it with the held directory.
        guard sourceParent.remainsMapped(), destinationParent.remainsMapped(),
              AIPackageFileIdentity(try entryStat(sourceParent.fd, source.lastPathComponent)) == digest.identity else { throw AIPackageError.changed }
        guard renameatx_np(sourceParent.fd, source.lastPathComponent, destinationParent.fd, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw AIPackageError.conflict(destination.path) }
        var movedIdentity: AIPackageFileIdentity?
        var movedSignature: String?
        do {
            movedIdentity = AIPackageFileIdentity(try entryStat(destinationParent.fd, destination.lastPathComponent))
            guard movedIdentity == digest.identity else { throw AIPackageError.changed }
            let after = try fingerprint(parentFD: destinationParent.fd, name: destination.lastPathComponent, logicalPackage: logicalPackage, logicalURL: logicalURL)
            movedSignature = after.signature
            guard after.signature == expected, sourceParent.remainsMapped(), destinationParent.remainsMapped() else { throw AIPackageError.changed }
        } catch {
            // A failed post-check must not strand an item under an obsolete expected hash.
            // Restore to the exact source directory FD only when its original name is still empty.
            if let movedIdentity, (try? entryStat(destinationParent.fd, destination.lastPathComponent)).map(AIPackageFileIdentity.init) == movedIdentity,
               renameatx_np(destinationParent.fd, destination.lastPathComponent, sourceParent.fd, source.lastPathComponent, UInt32(RENAME_EXCL)) == 0 {
                throw AIPackageError.changed
            }
            throw PackageRelocationFailure(location: destinationParent.actualURL(for: destination.lastPathComponent),
                                           identity: movedIdentity, signature: movedSignature)
        }
    }
}
