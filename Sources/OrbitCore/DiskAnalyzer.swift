import Foundation
import Darwin

public struct DiskEntry: Identifiable, Sendable {
    public let url: URL
    public let bytes: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public init(url: URL, bytes: Int64, fileCount: Int, isDirectory: Bool = false) {
        self.url = url; self.bytes = bytes; self.fileCount = fileCount; self.isDirectory = isDirectory
    }
}

public struct DiskReport: Sendable {
    public let root: URL
    public let entries: [DiskEntry]
    public let largeFiles: [DiskEntry]
    public let scannedFiles: Int
    public let warnings: [String]
    public let isPartial: Bool
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

public actor DiskAnalyzer {
    public init() {}

    public func scan(_ requestedRoot: URL, fileLimit: Int = 180_000, timeLimit: TimeInterval = 18, includeHidden: Bool = false) -> DiskReport {
        let fm = FileManager.default
        // The user selects the scan root; resolve that root once so enumeration and
        // relative grouping share the same path on macOS (/var -> /private/var).
        let root: URL
        if let resolved = realpath(requestedRoot.path, nil) {
            root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        } else {
            return DiskReport(root: requestedRoot, entries: [], largeFiles: [], scannedFiles: 0, warnings: ["无法打开此文件夹"], isPartial: true)
        }
        var warnings: [String] = []
        var totals: [URL: (Int64, Int)] = [:]
        var files: [DiskEntry] = []
        var count = 0
        var partial = false
        let started = ProcessInfo.processInfo.systemUptime
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        var directories: Set<URL> = []
        if let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: includeHidden ? [] : [.skipsHiddenFiles]) {
            for child in children {
                guard let values = try? child.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true { directories.insert(child); totals[child] = (0, 0) }
            }
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: options, errorHandler: { url, _ in
            if warnings.count < 8 { warnings.append("无法读取：\(url.path)") }
            partial = true
            return true
        }) else {
            return DiskReport(root: root, entries: [], largeFiles: [], scannedFiles: 0, warnings: ["无法打开此文件夹"], isPartial: true)
        }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled || count >= fileLimit || ProcessInfo.processInfo.systemUptime - started >= timeLimit {
                partial = true
                warnings.append(Task.isCancelled ? "扫描已取消" : "已达到扫描上限；以下是已读取的内容")
                break
            }
            guard let values = try? url.resourceValues(forKeys: keys) else { partial = true; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if url.lastPathComponent == ".git" && !includeHidden { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            count += 1
            let bytes = Int64(values.fileSize ?? 0)
            let relative = url.path.dropFirst(root.path.count).split(separator: "/")
            guard let first = relative.first else { continue }
            let group = root.appendingPathComponent(String(first))
            let old = totals[group] ?? (0, 0)
            totals[group] = (old.0 + bytes, old.1 + 1)
            if bytes >= 10_000_000 {
                files.append(DiskEntry(url: url, bytes: bytes, fileCount: 1))
                if files.count > 160 { files = Array(files.sorted { $0.bytes > $1.bytes }.prefix(80)) }
            }
        }
        return DiskReport(root: root,
                          entries: totals.map { DiskEntry(url: $0.key, bytes: $0.value.0, fileCount: $0.value.1, isDirectory: directories.contains($0.key)) }.sorted { $0.bytes > $1.bytes },
                          largeFiles: Array(files.sorted { $0.bytes > $1.bytes }.prefix(80)),
                          scannedFiles: count, warnings: warnings, isPartial: partial)
    }
}
