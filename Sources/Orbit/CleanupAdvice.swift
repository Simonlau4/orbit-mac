import Foundation
import AppKit
import OrbitCore

enum CleanupTier: Int, CaseIterable, Sendable {
    case recommended, decide
    var title: String { self == .recommended ? "推荐清理" : "需要你决定" }
    var note: String { self == .recommended ? "删了会自动重建" : "能删，但有代价" }
    init(_ category: CleanupCategory) {
        self = category == .developer || category == .installers ? .decide : .recommended
    }
}

struct CleanupAdvice: Equatable, Sendable {
    let title: String
    let detail: String
    /// Moves a row to "需要你决定" whatever its category.
    var decide = false
}

enum CleanupAdvisor {
    private static let download = "安装依赖时留下的下载副本，下次需要会重新下载"
    private static let cache = "App 运行时生成的临时文件，需要时会重新生成"
    private static let log = "过去的运行记录，只在排查问题时有用"
    // Matched against the lowercased folder path with a trailing slash; first match wins.
    private static let knownLocations: [(String, String, String)] = [
        ("/.npm/_cacache/", "npm 下载缓存", download),
        ("/.cache/pip/", "pip 下载缓存", download),
        ("/caches/pip/", "pip 下载缓存", download),
        ("/.bun/install/cache/", "Bun 下载缓存", download),
        ("/corepack/", "Corepack 下载的包管理器", "pnpm、Yarn 等工具的安装副本，用到时会重新下载"),
        ("/caches/pnpm/", "pnpm 下载缓存", download),
        ("/caches/yarn/", "Yarn 下载缓存", download),
        ("/caches/ms-playwright/", "Playwright 临时文件", "自动化测试运行时留下的文件，需要时会重新生成"),
        ("/chrome-headless/", "无界面 Chrome 缓存", "自动化工具打开的临时浏览器留下的缓存"),
        ("mediaanalysisd", "照片与视频分析缓存", "macOS 识别照片内容的中间结果，空闲时会自动重建"),
        ("photoanalysisd", "照片分析缓存", "macOS 识别照片内容的中间结果，空闲时会自动重建"),
        ("e5bundlecache", "系统 AI 模型编译缓存", "macOS 需要时会重新编译"),
        ("/geoservices/", "地图缓存", "打开地图时会重新下载"),
        ("com.apple.geod", "地图缓存", "打开地图时会重新下载"),
        ("fontconfig", "字体索引缓存", "需要时会自动重建"),
        ("/claude-cli-nodejs/", "Claude Code 旧日志", log),
        ("/cursor-compile-cache/", "Cursor 编译缓存", "Cursor 启动时会重新生成")
    ]

    static func advice(name: String, category: CleanupCategory, location: URL, appName: (String) -> String? = installedAppName) -> CleanupAdvice {
        if category == .installers { return CleanupAdvice(title: "下载文件夹里的旧安装包", detail: "30 天前下载的 DMG、PKG，重装软件时需要重新下载") }
        if category == .developer {
            let parts = name.components(separatedBy: " · ")
            guard parts.count == 2, BuildOutputs.names.contains(parts[1]) else { return CleanupAdvice(title: "Xcode 构建缓存", detail: "下次编译会重新生成，首次编译会慢一些") }
            let kind = parts[1] == ".next" ? "Next.js" : parts[1] == ".build" ? "Swift" : "Xcode"
            return CleanupAdvice(title: parts[0] + " 项目的 \(kind) 构建产物", detail: shortPath(location.deletingLastPathComponent()) + " · 下次运行或编译时重新生成，首次会慢几分钟")
        }
        let path = location.path.lowercased() + "/", lower = name.lowercased()
        if let (_, title, detail) = knownLocations.first(where: { path.contains($0.0) }) { return CleanupAdvice(title: title, detail: detail) }
        if lower.hasSuffix("· 散落文件") {
            return category == .logs ? CleanupAdvice(title: "日志文件夹里的零散文件", detail: log) : CleanupAdvice(title: "缓存文件夹里的零散文件", detail: cache)
        }
        if lower.hasSuffix(".shipit") || lower.contains("updater") || path.contains("/updates/") || path.contains("sparkle") {
            var base = displayName(name, appName: appName)
            for suffix in ["-updater", " updater", "updater"] where base.lowercased().hasSuffix(suffix) { base = String(base.dropLast(suffix.count)); break }
            if base.hasPrefix("@") { base.removeFirst() }
            return CleanupAdvice(title: base + " 旧更新包", detail: "可能含还没安装的新版本，删了下次更新要重新下载", decide: true)
        }
        let app = displayName(name, appName: appName)
        if category == .logs || path.contains("/logs/") { return CleanupAdvice(title: app + " 旧日志", detail: log) }
        if category == .browserCache {
            let parts = name.components(separatedBy: " · ")
            let title = name.contains("缓存") ? name : parts[0] + " 网页缓存" + (parts.count > 1 && parts[1] != "Default" ? "（\(parts[1])）" : "")
            return CleanupAdvice(title: title, detail: "网页图片和脚本的临时副本，再次打开网页时重新下载")
        }
        if path.contains("fscacheddata") || path.contains("networkcache") { return CleanupAdvice(title: app + " 网络缓存", detail: "联网时下载的临时副本，需要时会重新下载") }
        return CleanupAdvice(title: app + " 缓存", detail: cache)
    }

    /// Turns a bundle identifier or folder name into the name people see in Finder.
    static func displayName(_ name: String, appName: (String) -> String? = installedAppName) -> String {
        var id = name
        if id.lowercased().hasSuffix(".shipit") { id = String(id.dropLast(7)) }
        guard id.contains("."), !id.contains(" ") else { return id }
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if let resolved = appName(parts.joined(separator: ".")) { return resolved }
            parts.removeLast()
        }
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return id.hasPrefix("com.apple.") ? "macOS " + last : last
    }
}

func installedAppName(_ bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}
