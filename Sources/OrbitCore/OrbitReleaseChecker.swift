import Foundation

public struct OrbitRelease: Sendable, Equatable {
    public let version: String
    public let url: URL
}

/// Orbit's own release notifications; unrelated to installing updates for other apps.
public struct OrbitReleaseChecker: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func availableRelease(after currentVersion: String) async throws -> OrbitRelease? {
        guard let current = Self.versionParts(currentVersion) else { throw CheckError.invalidVersion }
        let url = URL(string: "https://api.github.com/repos/Simonlau4/orbit-mac/releases?per_page=20")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Orbit/" + currentVersion, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CheckError.unavailable }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> (parts: [Int], release: OrbitRelease)? in
            guard !release.draft, let parts = Self.versionParts(release.tag_name),
                  current.lexicographicallyPrecedes(parts) else { return nil }
            let version = parts.map(String.init).joined(separator: ".")
            let root = "https://github.com/Simonlau4/orbit-mac/releases/"
            let downloadable = release.assets.contains { asset in
                let names = ["Orbit-\(version)-universal.dmg", "Orbit-\(version)-universal.zip"]
                return asset.state == "uploaded" && names.contains(asset.name) &&
                    asset.browser_download_url == root + "download/" + release.tag_name + "/" + asset.name
            }
            guard downloadable, let url = URL(string: root + "tag/" + release.tag_name) else { return nil }
            return (parts, OrbitRelease(version: version, url: url))
        }.max { $0.parts.lexicographicallyPrecedes($1.parts) }?.release
    }

    private static func versionParts(_ value: String) -> [Int]? {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let parts = fields.compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let state: String
        let browser_download_url: String
    }
    private enum CheckError: LocalizedError {
        case invalidVersion, unavailable
        var errorDescription: String? {
            switch self {
            case .invalidVersion: return "无法读取当前 Orbit 版本。"
            case .unavailable: return "GitHub 暂时无法检查更新，请稍后重试。"
            }
        }
    }
}
