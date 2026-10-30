import XCTest
import Darwin
@testable import OrbitCore

final class AppManagementTests: XCTestCase {
    private var fixture: URL!
    override func setUpWithError() throws {
        let resolved = realpath(FileManager.default.temporaryDirectory.path, nil)!
        fixture = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("orbit-apps-" + UUID().uuidString)
        free(resolved)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixture) }

    @discardableResult private func app(_ path: String, id: String = "com.example.editor") throws -> URL {
        let url = fixture.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": "Fixture Editor", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.9", "CFBundleVersion": "19", "SUFeedURL": "https://example.com/appcast.xml"], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    @discardableResult private func file(_ path: String, size: Int = 10) throws -> URL {
        let url = fixture.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: size).write(to: url)
        return url
    }

    func testInventoryRecursesUtilitiesButDoesNotEnterBundlesOrFollowLinks() async throws {
        let editor = try app("Applications/Utilities/Editor.app")
        try app("Applications/Outer.app", id: "com.example.outer")
        try app("Applications/Outer.app/Contents/Nested.app", id: "com.example.nested")
        let outside = try app("Elsewhere/Linked.app", id: "com.example.linked")
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("Applications/Alias.app"), withDestinationURL: outside)
        let result = await ApplicationInventory().scan(roots: [fixture.appendingPathComponent("Applications")])
        XCTAssertEqual(result.apps.count, 2)
        let found = try XCTUnwrap(result.apps.first { $0.url.path == editor.path })
        XCTAssertEqual(found.bundleID, "com.example.editor")
        XCTAssertEqual(found.version, "1.9")
        XCTAssertFalse(result.apps.contains { ["com.example.nested", "com.example.linked"].contains($0.bundleID) })
    }

    func testRemnantsUseExplicitIdentityAndExcludeInstalledHelperAndLinks() async throws {
        let home = fixture.appendingPathComponent("home")
        let exact = try file("home/Library/Preferences/com.example.editor.plist", size: 27)
        let shared = try file("home/Library/Caches/com.example.editor.old/helper.bin")
        try file("home/Library/Caches/com.example.editor.helper/helper.bin")
        try file("home/Library/Application Support/Editor/my-document.txt")
        let outside = try file("outside/important.bin")
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("home/Library/Caches/com.example.editor.link"), withDestinationURL: outside)
        let scan = await AppRemnantScanner(home: home).scan(bundleID: "com.example.editor", installedBundleIDs: ["com.example.editor", "com.example.editor.helper"])
        XCTAssertEqual(Set(scan.items.map(\.url)), [exact, shared.deletingLastPathComponent()])
        XCTAssertEqual(scan.items.first { $0.url == exact }?.bytes, 27)
        XCTAssertFalse(scan.items.first { $0.url == exact }?.sharedRisk ?? true)
        XCTAssertTrue(scan.items.first { $0.url == shared.deletingLastPathComponent() }?.sharedRisk ?? false)
        XCTAssertFalse(scan.warnings.isEmpty)
        let apple = await AppRemnantScanner(home: home).scan(bundleID: "com.apple.Safari")
        XCTAssertTrue(apple.items.isEmpty)
    }

    func testOrphansAreOnlyCandidatesAndRemainUnselectedSharedRisk() async throws {
        try file("home/Library/Preferences/com.example.removed.plist")
        try file("home/Library/Preferences/com.example.present.plist")
        try file("home/Library/Preferences/com.apple.system.plist")
        let scan = await AppRemnantScanner(home: fixture.appendingPathComponent("home")).scanOrphans(installedBundleIDs: ["com.example.present"])
        XCTAssertEqual(scan.items.map(\.bundleID), ["com.example.removed"])
        XCTAssertTrue(scan.items.allSatisfy(\.sharedRisk))
        XCTAssertFalse(scan.warnings.isEmpty)
    }

    func testAppcastVersionComparisonAndUnsafeLinks() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure sparkle:version="20" sparkle:shortVersionString="1.10" url="https://example.com/20.zip" /></item>
        <item><enclosure sparkle:version="19" sparkle:shortVersionString="1.9" url="https://example.com/19.zip" /></item>
        </channel></rss>
        """
        let old = AppDescriptor(url: fixture, name: "Editor", bundleID: "com.example.editor", version: "1.9", buildVersion: "19")
        let result = try AppUpdateChecker.parse(data: Data(xml.utf8), app: old, sourceURL: URL(string: "https://example.com/appcast.xml")!)
        XCTAssertEqual(result.state, .updateAvailable)
        XCTAssertEqual(result.availableVersion, "1.10")
        XCTAssertEqual(result.downloadURL?.lastPathComponent, "20.zip")
        let current = AppDescriptor(url: fixture, name: "Editor", bundleID: old.bundleID, version: "1.10", buildVersion: "20")
        XCTAssertEqual(try AppUpdateChecker.parse(data: Data(xml.utf8), app: current, sourceURL: result.sourceURL!).state, .current)
        for raw in ["file:///etc/passwd", "http://example.com/feed", "https://localhost/feed", "https://127.0.0.1/feed", "https://192.168.1.1/feed", "https://[::1]/feed", "https://100.64.0.1/feed", "https://user:pass@example.com/feed"] {
            XCTAssertThrowsError(try AppUpdateChecker.validateFeedURL(URL(string: raw)!))
        }
    }

    func testAppcastRejectsEntityDeclarationsAndMissingVersions() throws {
        let app = AppDescriptor(url: fixture, name: "Fixture", bundleID: "com.example.app", version: "1")
        let source = URL(string: "https://example.com/feed")!
        XCTAssertThrowsError(try AppUpdateChecker.parse(data: Data("<rss><channel/></rss>".utf8), app: app, sourceURL: source))
        let entity = "<!DOCTYPE rss [<!ENTITY local SYSTEM 'file:///etc/passwd'>]><rss>&local;</rss>"
        XCTAssertThrowsError(try AppUpdateChecker.parse(data: Data(entity.utf8), app: app, sourceURL: source))
    }

    func testModernAppcastElementVersionsIgnoreDeltaEnclosures() throws {
        let app = AppDescriptor(url: fixture, name: "Fixture", bundleID: "com.example.app", version: "1.16.0", buildVersion: "324")
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>343</sparkle:version><sparkle:shortVersionString>1.18.0</sparkle:shortVersionString>
        <enclosure url="https://example.com/complete.dmg"/>
        <sparkle:deltas><enclosure sparkle:version="343" sparkle:shortVersionString="1.18.0" url="https://example.com/partial.delta"/></sparkle:deltas>
        </item></channel></rss>
        """
        let result = try AppUpdateChecker.parse(data: Data(xml.utf8), app: app, sourceURL: URL(string: "https://example.com/feed")!)
        XCTAssertEqual(result.state, .updateAvailable)
        XCTAssertEqual(result.availableVersion, "1.18.0")
        XCTAssertEqual(result.downloadURL?.lastPathComponent, "complete.dmg")
    }

    func testRemnantCandidateLimitIsSharedAcrossOrphanIdentifiers() async throws {
        try file("home/Library/Preferences/com.example.first.plist")
        try file("home/Library/Preferences/com.example.second.plist")
        let scanner = AppRemnantScanner(home: fixture.appendingPathComponent("home"), maximumItems: 1)
        let scan = await scanner.scanOrphans(installedBundleIDs: [])
        XCTAssertEqual(scan.items.count, 1)
        XCTAssertTrue(scan.warnings.contains { $0.contains("候选上限") })
    }

    func testRemnantFileBudgetIncludesAllCandidateContents() async throws {
        for index in 0..<6 {
            try file("home/Library/Caches/com.example.first/\(index).bin")
            try file("home/Library/Caches/com.example.second/\(index).bin")
        }
        let scanner = AppRemnantScanner(home: fixture.appendingPathComponent("home"), maximumFiles: 12)
        let scan = await scanner.scanOrphans(installedBundleIDs: [])
        XCTAssertEqual(scan.items.count, 1)
        XCTAssertTrue(scan.warnings.contains { $0.contains("全局文件访问上限") })
    }

    func testRemnantDeadlineAndCancellationReportPartialCoverage() async throws {
        try file("home/Library/Preferences/com.example.editor.plist")
        let home = fixture.appendingPathComponent("home")
        let deadline = await AppRemnantScanner(home: home, timeLimit: 0).scan(bundleID: "com.example.editor")
        XCTAssertTrue(deadline.items.isEmpty)
        XCTAssertTrue(deadline.warnings.contains { $0.contains("总时间上限") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await AppRemnantScanner(home: home).scanOrphans(installedBundleIDs: [])
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.items.isEmpty)
        XCTAssertTrue(cancelled.warnings.contains { $0.contains("已取消") })
    }
}
