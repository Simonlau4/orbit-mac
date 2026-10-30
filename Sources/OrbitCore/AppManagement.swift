import Foundation
import Darwin

public struct AppDescriptor: Codable, Identifiable, Sendable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let buildVersion: String
    public let appcastURL: URL?
    public let isSystem: Bool
    public var id: String { url.path }

    public init(url: URL, name: String, bundleID: String, version: String, buildVersion: String = "", appcastURL: URL? = nil, isSystem: Bool = false) {
        self.url = url; self.name = name; self.bundleID = bundleID
        self.version = version; self.buildVersion = buildVersion
        self.appcastURL = appcastURL; self.isSystem = isSystem
    }
}

public struct ApplicationScan: Sendable {
    public let apps: [AppDescriptor]
    public let warnings: [String]
}

public actor ApplicationInventory {
    public init() {}

    public func scan(roots: [URL]? = nil) -> ApplicationScan {
        let fm = FileManager.default
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications")]
        var apps: [AppDescriptor] = []
        var warnings: [String] = []
        var seen: Set<String> = []
        func visit(_ folder: URL, depth: Int) {
            guard !Task.isCancelled, depth <= 2 else { return }
            do {
                try ApplicationPaths.noLinks(folder)
                for child in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true, values.isDirectory == true else { continue }
                    if child.pathExtension.lowercased() == "app" {
                        guard seen.insert(child.path).inserted, let bundle = Bundle(url: child) else { continue }
                        let identifier = bundle.bundleIdentifier ?? ""
                        let info = bundle.infoDictionary ?? [:]
                        apps.append(AppDescriptor(url: child, name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? child.deletingPathExtension().lastPathComponent,
                                                  bundleID: identifier, version: info["CFBundleShortVersionString"] as? String ?? "—", buildVersion: info["CFBundleVersion"] as? String ?? "",
                                                  appcastURL: (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), isSystem: identifier.hasPrefix("com.apple.") || child.path.hasPrefix("/System/")))
                    } else if depth < 2 { visit(child, depth: depth + 1) }
                }
            } catch {
                if fm.fileExists(atPath: folder.path), warnings.count < 12 { warnings.append("无法读取应用目录：\(folder.path)") }
            }
        }
        for root in roots { visit(root, depth: 0) }
        return ApplicationScan(apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings)
    }

    public func size(of url: URL) throws -> Int64 { try ApplicationPaths.logicalSize(url) }
}

public struct RemnantCandidate: Identifiable, Sendable, Hashable {
    public let url: URL
    public let bundleID: String
    public let reason: String
    public let bytes: Int64
    public let sharedRisk: Bool
    public var id: String { url.path }
}

public struct RemnantScan: Sendable {
    public let items: [RemnantCandidate]
    public let warnings: [String]
    public let allowedRoots: [URL]
}

public actor AppRemnantScanner {
    private let home: URL
    private let timeLimit: TimeInterval
    private let maximumItems: Int
    private let maximumFiles: Int

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, timeLimit: TimeInterval = 20, maximumItems: Int = 1_000, maximumFiles: Int = 100_000) {
        self.home = home; self.timeLimit = max(0, timeLimit)
        self.maximumItems = max(0, maximumItems); self.maximumFiles = max(0, maximumFiles)
    }

    public func scan(for app: AppDescriptor, installedBundleIDs: Set<String> = []) -> RemnantScan {
        scan(bundleID: app.bundleID, installedBundleIDs: installedBundleIDs)
    }

    public func scan(bundleID: String, installedBundleIDs: Set<String> = []) -> RemnantScan {
        let roots = rootsForScan
        guard eligibleIdentifier(bundleID) else {
            return RemnantScan(items: [], warnings: ["系统应用或缺少明确标识的应用不扫描数据残留。"], allowedRoots: roots)
        }
        let fm = FileManager.default
        var budget = makeBudget()
        var items: [RemnantCandidate] = []
        var warnings: [String] = []
        do {
            try budget.check()
            for root in roots where fm.fileExists(atPath: root.path) {
                try budget.check()
                do { try ApplicationPaths.noLinks(root) }
                catch { if warnings.count < 20 { warnings.append("无法读取：\(root.path)") }; continue }
                for url in children(of: root, warnings: &warnings) {
                    try budget.visit()
                    let name = url.lastPathComponent
                    let exact = name == bundleID || name == bundleID + ".plist" || name == bundleID + ".savedState"
                    guard exact || name.hasPrefix(bundleID + ".") else { continue }
                    if installedBundleIDs.contains(where: { $0 != bundleID && (name == $0 || name.hasPrefix($0 + ".")) }) { continue }
                    do {
                        if let item = try candidate(url, bundleID: bundleID, exact: exact, budget: &budget) { items.append(item) }
                    } catch let stop as RemnantScanStop { throw stop }
                    catch { if warnings.count < 20 { warnings.append("未能读取：\(url.path)") } }
                }
            }
        } catch let stop as RemnantScanStop { warnings.append(stop.message) }
        catch { warnings.append("部分残留目录无法读取，结果仅覆盖已检查内容。") }
        return RemnantScan(items: items.sorted { $0.bytes > $1.bytes }, warnings: warnings, allowedRoots: roots)
    }

    public func scanOrphans(installedBundleIDs: Set<String>) -> RemnantScan {
        var identifiers: Set<String> = []
        var paths: [String: [URL]] = [:]
        var budget = makeBudget()
        var items: [RemnantCandidate] = []
        var warnings = ["这些标识未在已扫描的应用目录中找到，仍可能属于辅助程序或其他位置的应用；默认不选择。"]
        do {
            try budget.check()
            discovery: for root in rootsForScan where FileManager.default.fileExists(atPath: root.path) {
                try budget.check()
                do { try ApplicationPaths.noLinks(root) }
                catch { if warnings.count < 20 { warnings.append("无法读取：\(root.path)") }; continue }
                for url in children(of: root, warnings: &warnings) {
                    try budget.visit()
                    var name = url.lastPathComponent
                    for suffix in [".plist", ".savedState"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
                    guard eligibleIdentifier(name), !name.hasPrefix("group."), !installedBundleIDs.contains(name), !installedBundleIDs.contains(where: { name.hasPrefix($0 + ".") }) else { continue }
                    if !identifiers.contains(name), identifiers.count >= 200 {
                        warnings.append("仅检查前 200 个标识，结果并非完整系统残留清单。")
                        break discovery
                    }
                    identifiers.insert(name)
                    paths[name, default: []].append(url)
                }
            }
            // Inventory each root once, then size its candidates under the same deadline.
            for identifier in identifiers.sorted() {
                for url in paths[identifier] ?? [] {
                    do {
                        if let item = try candidate(url, bundleID: identifier, exact: false, budget: &budget) {
                            items.append(RemnantCandidate(url: item.url, bundleID: identifier, reason: "未在已扫描应用中找到此标识；需手动核对", bytes: item.bytes, sharedRisk: true))
                        }
                    } catch let stop as RemnantScanStop { throw stop }
                    catch { if warnings.count < 20 { warnings.append("未能读取：\(url.path)") } }
                }
            }
        } catch let stop as RemnantScanStop { warnings.append(stop.message) }
        catch { warnings.append("部分残留目录无法读取，结果仅覆盖已检查内容。") }
        return RemnantScan(items: items.sorted { $0.bytes > $1.bytes }, warnings: warnings, allowedRoots: rootsForScan)
    }

    private func eligibleIdentifier(_ value: String) -> Bool {
        ApplicationPaths.validBundleID(value) && !value.hasPrefix("com.apple.") && value.lowercased() != "com.orbitmac.orbit"
    }

    private func makeBudget() -> RemnantScanBudget {
        RemnantScanBudget(deadline: ProcessInfo.processInfo.systemUptime + timeLimit, maximumItems: maximumItems, maximumFiles: maximumFiles)
    }

    private func children(of root: URL, warnings: inout [String]) -> [URL] {
        do { return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch { if warnings.count < 20 { warnings.append("无法读取：\(root.path)") }; return [] }
    }

    private func candidate(_ url: URL, bundleID: String, exact: Bool, budget: inout RemnantScanBudget) throws -> RemnantCandidate? {
        try budget.check()
        guard !budget.acceptedPaths.contains(url.path) else { return nil }
        guard budget.acceptedPaths.count < budget.maximumItems else { throw RemnantScanStop.items }
        try ApplicationPaths.noLinks(url)
        let bytes = try ApplicationPaths.logicalSize(url, budgetCheck: { try budget.visit() })
        budget.acceptedPaths.insert(url.path)
        return RemnantCandidate(url: url, bundleID: bundleID, reason: exact ? "与应用标识 \(bundleID) 精确对应" : "以应用标识开头，可能由辅助程序共享；请逐项核对", bytes: bytes, sharedRisk: !exact)
    }

    private var rootsForScan: [URL] {
        ["Caches", "Logs", "Preferences", "Preferences/ByHost", "Application Support", "Saved Application State", "HTTPStorages", "WebKit"].map { home.appendingPathComponent("Library/" + $0) }
    }
}

private struct RemnantScanBudget {
    let deadline: TimeInterval
    let maximumItems: Int
    let maximumFiles: Int
    var visited = 0
    var acceptedPaths: Set<String> = []
    mutating func visit() throws {
        try check()
        guard visited < maximumFiles else { throw RemnantScanStop.files }
        visited += 1
    }
    func check() throws {
        if Task.isCancelled { throw RemnantScanStop.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw RemnantScanStop.time }
    }
}

private enum RemnantScanStop: Error {
    case cancelled, time, files, items
    var message: String {
        switch self {
        case .cancelled: return "残留扫描已取消；结果仅覆盖已检查内容。"
        case .time: return "残留扫描达到总时间上限；结果仅覆盖已检查内容。"
        case .files: return "残留扫描达到全局文件访问上限；结果仅覆盖已检查内容。"
        case .items: return "残留扫描达到候选上限；结果仅覆盖已检查内容。"
        }
    }
}

public enum AppUpdateState: String, Codable, Sendable { case unsupported, current, updateAvailable, failed }

public struct AppUpdateRelease: Codable, Sendable, Equatable {
    public let sourceURL: URL
    public let downloadURL: URL
    public let version: String
    public let buildVersion: String
    public let edSignature: String?
    public let expectedLength: Int64?
    public let minimumSystemVersion: String?
    public let maximumSystemVersion: String?
    public let architectures: [String]
    public let installationType: String

    public init(sourceURL: URL, downloadURL: URL, version: String, buildVersion: String,
                edSignature: String? = nil, expectedLength: Int64? = nil,
                minimumSystemVersion: String? = nil, maximumSystemVersion: String? = nil,
                architectures: [String] = [], installationType: String = "application") {
        self.sourceURL = sourceURL; self.downloadURL = downloadURL; self.version = version
        self.buildVersion = buildVersion; self.edSignature = edSignature; self.expectedLength = expectedLength
        self.minimumSystemVersion = minimumSystemVersion; self.maximumSystemVersion = maximumSystemVersion
        self.architectures = architectures; self.installationType = installationType
    }
}

public struct AppUpdateResult: Sendable {
    public let state: AppUpdateState
    public let installedVersion: String
    public let availableVersion: String?
    public let sourceURL: URL?
    public let downloadURL: URL?
    public let message: String
    public let release: AppUpdateRelease?

    public init(state: AppUpdateState, installedVersion: String, availableVersion: String? = nil,
                sourceURL: URL? = nil, downloadURL: URL? = nil, message: String, release: AppUpdateRelease? = nil) {
        self.state = state; self.installedVersion = installedVersion; self.availableVersion = availableVersion
        self.sourceURL = sourceURL; self.downloadURL = downloadURL; self.message = message; self.release = release
    }
}

public actor AppUpdateChecker {
    public init() {}

    public func check(_ app: AppDescriptor) async -> AppUpdateResult {
        guard let url = app.appcastURL else { return result(.unsupported, app, message: "此应用未声明 Sparkle 更新源；请使用应用自身或 App Store 检查更新。") }
        do {
            try Self.validateFeedURL(url, resolveHost: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: AppcastRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= 2_097_152 else { throw AppManagementError.invalidFeed }
            var data = Data()
            for try await byte in stream {
                guard data.count < 2_097_152 else { throw AppManagementError.invalidFeed }
                data.append(byte)
            }
            return try Self.parse(data: data, app: app, sourceURL: response.url ?? url)
        } catch { return result(.failed, app, source: url, message: "更新检查失败：\(error.localizedDescription)") }
    }

    public static func parse(data: Data, app: AppDescriptor, sourceURL: URL) throws -> AppUpdateResult {
        guard data.count <= 2_097_152 else { throw AppManagementError.invalidFeed }
        try validateFeedURL(sourceURL)
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw AppManagementError.invalidFeed }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let compatible = delegate.items.filter { item in
            (item.minimumOS.map { osVersion.compare($0, options: .numeric) != .orderedAscending } ?? true)
                && (item.maximumOS.map { osVersion.compare($0, options: .numeric) != .orderedDescending } ?? true)
                && (item.architectures.isEmpty || item.architectures.contains(architecture) || item.architectures.contains("universal"))
        }
        guard let latest = compatible.max(by: { $0.build.compare($1.build, options: .numeric) == .orderedAscending }) else { throw AppManagementError.invalidFeed }
        let installed = app.buildVersion.isEmpty ? app.version : app.buildVersion
        let latestComparison = latest.build.isEmpty ? latest.version : latest.build
        let available = latest.version.isEmpty ? latest.build : latest.version
        let newer = latestComparison.compare(installed, options: .numeric) == .orderedDescending
        let download = latest.url.flatMap { (try? validateFeedURL($0)) == nil ? nil : $0 }
        let release = download.map { AppUpdateRelease(sourceURL: sourceURL, downloadURL: $0, version: available,
                                                      buildVersion: latestComparison, edSignature: latest.signature,
                                                      expectedLength: latest.length, minimumSystemVersion: latest.minimumOS,
                                                      maximumSystemVersion: latest.maximumOS, architectures: latest.architectures,
                                                      installationType: latest.installationType) }
        return AppUpdateResult(state: newer ? .updateAvailable : .current, installedVersion: app.version, availableVersion: available,
                               sourceURL: sourceURL, downloadURL: download,
                               message: newer ? "更新源提供 \(available)。安装前将验证下载签名、应用身份与系统兼容性。" : "在此应用声明的更新源中未发现更高版本。", release: release)
    }

    public static func validateFeedURL(_ url: URL, resolveHost: Bool = false) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"), !host.hasSuffix(".home"), host != "metadata.google.internal" else { throw AppManagementError.invalidFeedURL }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { guard isPublicAddress(host) else { throw AppManagementError.invalidFeedURL } }
        if resolveHost {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var records: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &records) == 0, let first = records else { throw AppManagementError.unresolvedHost }
            defer { freeaddrinfo(first) }
            var next: UnsafeMutablePointer<addrinfo>? = first
            while let current = next {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { throw AppManagementError.invalidFeedURL }
                let address = String(cString: buffer)
                // Clash/Mihomo maps public hostnames to its 198.18/15 synthetic pool.
                // Literal benchmark addresses are still rejected above; ordinary private,
                // link-local, CGNAT and loopback destinations remain prohibited.
                let octets = address.split(separator: ".").compactMap { Int(String($0)) }
                let syntheticProxyAddress = !host.allSatisfy({ $0.isNumber || $0 == "." }) && octets.count == 4 && octets[0] == 198 && [18, 19].contains(octets[1])
                guard isPublicAddress(address) || syntheticProxyAddress else { throw AppManagementError.invalidFeedURL }
                next = current.pointee.ai_next
            }
        }
    }

    private static func isPublicAddress(_ host: String) -> Bool {
        if host.contains(":") {
            guard !host.contains("."), let first = host.split(separator: ":").first.flatMap({ UInt16($0, radix: 16) }) else { return false }
            return (0x2000...0x3fff).contains(first) && !host.lowercased().hasPrefix("2001:db8:")
        }
        let bytes = host.split(separator: ".").compactMap { Int(String($0)) }
        guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = bytes[0], b = bytes[1]
        return a > 0 && a < 224 && a != 10 && a != 127 && !(a == 169 && b == 254) && !(a == 172 && (16...31).contains(b)) && !(a == 192 && (b == 168 || b == 0)) && !(a == 100 && (64...127).contains(b)) && !(a == 198 && (b == 18 || b == 19))
    }

    private func result(_ state: AppUpdateState, _ app: AppDescriptor, source: URL? = nil, message: String) -> AppUpdateResult {
        AppUpdateResult(state: state, installedVersion: app.version, availableVersion: nil, sourceURL: source, downloadURL: nil, message: message)
    }
}

private final class AppcastRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? AppUpdateChecker.validateFeedURL(url, resolveHost: true)) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var build = ""; var version = ""; var url: URL?
        var signature: String?; var length: Int64?; var minimumOS: String?; var maximumOS: String?
        var architectures: [String] = []; var installationType = "application"
    }
    var items: [Item] = []
    private var itemDepth = 0
    private var deltaDepth = 0
    private var current = Item()
    private var field: String?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "item" { itemDepth += 1; current = Item() }
        if elementName == "sparkle:deltas" { deltaDepth += 1 }
        if ["sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion", "sparkle:maximumSystemVersion"].contains(elementName), itemDepth > 0, deltaDepth == 0 { field = elementName; text = "" }
        if elementName == "enclosure", itemDepth > 0, deltaDepth == 0 {
            if let os = attributes["sparkle:os"], os != "macos" { return }
            current.build = attributes["sparkle:version"] ?? attributes["version"] ?? current.build
            current.version = attributes["sparkle:shortVersionString"] ?? current.version
            current.url = attributes["url"].flatMap(URL.init(string:)) ?? current.url
            current.signature = attributes["sparkle:edSignature"]
            current.length = attributes["length"].flatMap(Int64.init)
            current.architectures = (attributes["sparkle:cpuArchitecture"] ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            current.installationType = attributes["sparkle:installationType"] ?? "application"
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string; if text.utf8.count > 4096 { parser.abortParsing() } }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == field {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "sparkle:version": current.build = value
            case "sparkle:shortVersionString": current.version = value
            case "sparkle:minimumSystemVersion": current.minimumOS = value
            case "sparkle:maximumSystemVersion": current.maximumOS = value
            default: break
            }
            field = nil
        }
        if elementName == "sparkle:deltas" { deltaDepth = max(0, deltaDepth - 1) }
        if elementName == "item" {
            if !current.build.isEmpty || !current.version.isEmpty {
                if current.build.isEmpty { current.build = current.version }
                if current.version.isEmpty { current.version = current.build }
                items.append(current)
            }
            itemDepth = max(0, itemDepth - 1)
        }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
}

enum AppManagementError: LocalizedError {
    case invalidFeedURL, unresolvedHost, invalidFeed, sizeLimit, linkedPath(String), unreadable(String)
    var errorDescription: String? {
        switch self {
        case .invalidFeedURL: return "更新源必须是公开 HTTPS 地址。"
        case .unresolvedHost: return "无法解析更新源地址。"
        case .invalidFeed: return "更新源没有可用的版本信息或超过大小限制。"
        case .sizeLimit: return "大小统计达到时间上限，请选择更小的范围。"
        case .linkedPath(let path): return "不跟随符号链接：\(path)"
        case .unreadable(let path): return "无法读取：\(path)"
        }
    }
}

enum ApplicationPaths {
    static func validBundleID(_ value: String) -> Bool {
        value.count >= 5 && value.contains(".") && !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..") && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    static func noLinks(_ url: URL) throws {
        guard url.isFileURL else { throw AppManagementError.unreadable(url.absoluteString) }
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var value = stat()
            guard lstat(current.path, &value) == 0 else { throw AppManagementError.unreadable(current.path) }
            if value.st_mode & S_IFMT == S_IFLNK { throw AppManagementError.linkedPath(current.path) }
        }
    }

    static func logicalSize(_ url: URL, budgetCheck: () throws -> Void = {}) throws -> Int64 {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        func check() throws {
            try budgetCheck()
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw AppManagementError.sizeLimit }
        }
        try check()
        try noLinks(url)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw AppManagementError.unreadable(url.path) }
        if metadata.st_mode & S_IFMT == S_IFREG { return max(0, metadata.st_size) }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else { throw AppManagementError.unreadable(url.path) }
        for case let child as URL in enumerator {
            try check()
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
}
