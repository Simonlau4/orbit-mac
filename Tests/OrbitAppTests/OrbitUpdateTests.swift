import XCTest
import OrbitCore
@testable import Orbit

@MainActor
final class OrbitUpdateTests: XCTestCase {
    private func checker(_ releases: [[String: Any]], status: Int = 200) throws -> OrbitReleaseChecker {
        ReleaseProtocol.data = try JSONSerialization.data(withJSONObject: releases)
        ReleaseProtocol.status = status
        ReleaseProtocol.requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        return OrbitReleaseChecker(session: URLSession(configuration: configuration))
    }
    private func release(_ version: String, draft: Bool = false, asset: Bool = true, state: String = "uploaded", external: Bool = false) -> [String: Any] {
        let name = "Orbit-\(version)-universal.dmg"
        return ["tag_name": "v" + version, "draft": draft, "prerelease": true,
                "assets": asset ? [["name": name, "state": state, "browser_download_url": external ? "https://example.com/" + name : "https://github.com/Simonlau4/orbit-mac/releases/download/v\(version)/\(name)"]] : []]
    }
    func testNumericOrderingFindsHighestDownloadableVersionIncludingPublishedPreview() async throws {
        let service = try checker([release("0.9.9"), release("0.10.0"), release("0.4.4")])
        let update = try await service.availableRelease(after: "0.4.3")
        XCTAssertEqual(update?.version, "0.10.0")
        XCTAssertEqual(update?.url.absoluteString, "https://github.com/Simonlau4/orbit-mac/releases/tag/v0.10.0")
    }
    func testSameOrOlderVersionsDoNotNotify() async throws {
        let service = try checker([release("0.4.3"), release("0.4.4")])
        let update = try await service.availableRelease(after: "0.4.4")
        XCTAssertNil(update)
    }
    func testDraftsUnfinishedUploadsMissingPackagesAndExternalDownloadsAreIgnored() async throws {
        let service = try checker([release("1.0.0", draft: true), release("0.9.0", asset: false),
                                   release("0.8.0", state: "new"), release("0.7.0", external: true), release("0.4.4")])
        let update = try await service.availableRelease(after: "0.4.3")
        XCTAssertEqual(update?.version, "0.4.4")
    }
    func testInvalidAndPrereleaseTagsDoNotBecomeDownloadLinks() async throws {
        var invalid = release("0.5.0")
        invalid["tag_name"] = "v0.5.0/../../other"
        let service = try checker([invalid, release("0.5.0-beta.1"), release("999999999999999999999.0.0"), release("0.4.4")])
        let update = try await service.availableRelease(after: "0.4.3")
        XCTAssertEqual(update?.version, "0.4.4")
    }
    func testZIPOnlyReleaseIsStillDownloadable() async throws {
        var zip = release("0.4.4")
        zip["assets"] = [["name": "Orbit-0.4.4-universal.zip", "state": "uploaded", "browser_download_url": "https://github.com/Simonlau4/orbit-mac/releases/download/v0.4.4/Orbit-0.4.4-universal.zip"]]
        let service = try checker([zip])
        let update = try await service.availableRelease(after: "0.4.3")
        XCTAssertEqual(update?.version, "0.4.4")
    }
    func testHTTPFailureIsNotReportedAsUpToDate() async throws {
        let service = try checker([], status: 403)
        let monitor = OrbitUpdateMonitor(version: "0.4.3", checker: service)
        await monitor.check()
        XCTAssertEqual(monitor.message, "检查更新失败，请稍后重试。")
        XCTAssertFalse(monitor.isChecking)
        XCTAssertNil(monitor.availableRelease)
    }
    func testEmptyFeedReportsUpToDate() async throws {
        let service = try checker([])
        let monitor = OrbitUpdateMonitor(version: "0.4.3", checker: service)
        await monitor.check()
        XCTAssertEqual(monitor.message, "当前已是最新版本")
        XCTAssertNil(monitor.availableRelease)
    }
    func testConcurrentChecksCoalesceAndFailureKeepsKnownUpdate() async throws {
        let service = try checker([release("0.4.4")])
        let monitor = OrbitUpdateMonitor(version: "0.4.3", checker: service)
        async let first: Void = monitor.check()
        async let second: Void = monitor.check()
        _ = await (first, second)
        XCTAssertEqual(ReleaseProtocol.requests, 1)
        XCTAssertEqual(monitor.availableRelease?.version, "0.4.4")
        ReleaseProtocol.status = 503
        await monitor.check()
        XCTAssertEqual(monitor.availableRelease?.version, "0.4.4")
        XCTAssertEqual(monitor.message, "检查更新失败，请稍后重试。")
    }
    func testInvalidCurrentVersionFailsBeforeNetworkAccess() async throws {
        let service = try checker([])
        do { _ = try await service.availableRelease(after: "unknown"); XCTFail("accepted invalid version") }
        catch { XCTAssertEqual(ReleaseProtocol.requests, 0) }
    }
}

private final class ReleaseProtocol: URLProtocol, @unchecked Sendable {
    static var data = Data()
    static var status = 200
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        XCTAssertEqual(request.url?.host, "api.github.com")
        XCTAssertEqual(request.url?.path, "/repos/Simonlau4/orbit-mac/releases")
        Thread.sleep(forTimeInterval: 0.05)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
