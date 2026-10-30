import Foundation
import Darwin

public enum ReadAccessStatus: String, Codable, Sendable {
    case readable, denied, missing, unavailable
}

public struct ReadAccessTarget: Identifiable, Sendable {
    public var id: String { url.path }
    public let title: String
    public let url: URL

    public init(title: String, url: URL) { self.title = title; self.url = url }
}

public struct ReadAccessEntry: Identifiable, Sendable {
    public var id: String { target.id }
    public let target: ReadAccessTarget
    public let status: ReadAccessStatus
    public let issue: CleanupScanIssue?

    public init(target: ReadAccessTarget, status: ReadAccessStatus, issue: CleanupScanIssue? = nil) {
        self.target = target; self.status = status; self.issue = issue
    }
}

/// Measures reads by the calling process. It never infers a TCC switch from these results.
public actor ReadAccessProbe {
    public init() {}

    public static func targets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ReadAccessTarget] {
        [ReadAccessTarget(title: "废纸篓", url: home.appendingPathComponent(".Trash")),
         ReadAccessTarget(title: "Safari 缓存", url: home.appendingPathComponent("Library/Caches/com.apple.Safari")),
         ReadAccessTarget(title: "家庭共享缓存", url: home.appendingPathComponent("Library/Caches/familycircled")),
         ReadAccessTarget(title: "CloudKit 缓存", url: home.appendingPathComponent("Library/Caches/CloudKit")),
         ReadAccessTarget(title: "应用容器", url: home.appendingPathComponent("Library/Containers")),
         ReadAccessTarget(title: "系统缓存", url: URL(fileURLWithPath: "/Library/Caches")),
         ReadAccessTarget(title: "模拟器系统缓存", url: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches")),
         ReadAccessTarget(title: "系统日志", url: URL(fileURLWithPath: "/private/var/log"))]
    }

    public func check(_ targets: [ReadAccessTarget]) async -> [ReadAccessEntry] {
        var seen: Set<String> = []
        var result: [ReadAccessEntry] = []
        for target in targets where seen.insert(target.id).inserted {
            if Task.isCancelled { break }
            do {
                var current = URL(fileURLWithPath: "/")
                for component in CleanupPaths.normalized(target.url).pathComponents.dropFirst() {
                    current.appendPathComponent(component)
                    var value = stat()
                    guard lstat(current.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    guard value.st_mode & S_IFMT != S_IFLNK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)) }
                }
                _ = try FileManager.default.contentsOfDirectory(at: target.url, includingPropertiesForKeys: nil, options: [])
                result.append(ReadAccessEntry(target: target, status: .readable))
            } catch {
                let native = error as NSError
                let issue = CleanupScanIssue.reading(error, at: target.url)
                let missing = (native.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(native.code))
                    || (native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code))
                result.append(ReadAccessEntry(target: target, status: issue.kind == .permission ? .denied : missing ? .missing : .unavailable, issue: issue))
            }
            await Task.yield()
        }
        return result
    }
}
