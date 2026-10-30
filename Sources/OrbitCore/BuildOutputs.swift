import Foundation
import Darwin

/// File count, size and newest change inside a folder. A folder moves only while this is unchanged.
public struct CleanupContentStamp: Codable, Hashable, Sendable {
    public let files: Int
    public let bytes: Int64
    public let newestNanoseconds: Int64
    public var newest: Date { Date(timeIntervalSince1970: Double(newestNanoseconds) / 1_000_000_000) }
}

/// Project build folders (.next, .build, DerivedData) handled as one whole folder each.
public enum BuildOutputs {
    public static let names: Set<String> = [".build", ".next", "DerivedData"]

    /// Reads the tree without following links. Hard links, special files and oversized trees stop the stamp.
    public static func stamp(_ url: URL, maximumEntries: Int = 300_000) throws -> CleanupContentStamp {
        var files = 0, bytes: Int64 = 0, newest: Int64 = 0, visited = 0
        var pending = [CleanupPaths.normalized(url).path]
        func nanoseconds(_ value: timespec) -> Int64 { Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec) }
        while let path = pending.popLast() {
            visited += 1
            guard visited <= maximumEntries else { throw CleanupError.unsupported(url.path) }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw CleanupError.unavailable(path) }
            newest = max(newest, nanoseconds(info.st_mtimespec), nanoseconds(info.st_ctimespec))
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { throw CleanupError.unavailable(path) }
                pending.append(contentsOf: children.map { path + "/" + $0 })
            case S_IFREG:
                guard info.st_nlink == 1 else { throw CleanupError.unsupported(path) }
                files += 1; bytes += max(0, info.st_size)
            case S_IFLNK: files += 1 // Moves with its folder; the target is never read.
            default: throw CleanupError.unsupported(path)
            }
        }
        return CleanupContentStamp(files: files, bytes: bytes, newestNanoseconds: newest)
    }

    /// A candidate only when nothing inside changed for `minimumAgeDays` and no process works inside the project.
    public static func candidate(_ url: URL, minimumAgeDays: Int, workingDirectories: [String], now: Date = Date()) -> CleanupItem? {
        let source = CleanupPaths.normalized(url)
        guard names.contains(source.lastPathComponent), !inUse(source, workingDirectories: workingDirectories),
              (try? CleanupPaths.noSymlinks(source)) != nil, (try? CleanupPaths.notProtected(source)) != nil,
              let fingerprint = try? CleanupPaths.fingerprint(source), fingerprint.isDirectory,
              let contents = try? stamp(source), contents.files > 0,
              contents.newest <= now.addingTimeInterval(-Double(minimumAgeDays) * 86_400) else { return nil }
        return CleanupItem(url: source, category: .developer, bytes: contents.bytes, modifiedAt: contents.newest,
                           fingerprint: fingerprint, contents: contents)
    }

    public static func inUse(_ url: URL, workingDirectories: [String]) -> Bool {
        let project = CleanupPaths.normalized(url).deletingLastPathComponent().path
        return workingDirectories.contains { $0 == project || $0.hasPrefix(project + "/") }
    }

    /// Current directories of processes this user can inspect; nil when the process list is unavailable.
    public static func workingDirectories() -> [String]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2 + 256)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0, found <= pids.count else { return nil }
        var result: [String] = []
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if !path.isEmpty { result.append(CleanupPaths.normalized(URL(fileURLWithPath: path)).path) }
        }
        return result
    }
}
