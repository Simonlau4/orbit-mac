import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import OrbitCore

final class AppUpdateInstallerTests: XCTestCase {
    private var root: URL!
    private var key: Curve25519.Signing.PrivateKey!

    override func setUpWithError() throws {
        let actual = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(actual) }
        root = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        key = Curve25519.Signing.PrivateKey()
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    func testEd25519AuthenticatesFullArchiveAndLength() throws {
        let file = root.appendingPathComponent("bytes.zip")
        let bytes = Data("signed-archive-bytes".utf8); try bytes.write(to: file)
        let signature = try key.signature(for: bytes).base64EncodedString()
        try AppUpdateInstaller.verifyArchive(file, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), expectedLength: Int64(bytes.count))
        XCTAssertThrowsError(try AppUpdateInstaller.verifyArchive(file, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), expectedLength: 999))
        try Data("changed-archive".utf8).write(to: file)
        XCTAssertThrowsError(try AppUpdateInstaller.verifyArchive(file, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), expectedLength: nil))
    }

    func testExtractionRejectsTraversalAndOutwardSymlinkBeforeWritingOutside() throws {
        let traversal = root.appendingPathComponent("traversal.zip")
        try zipEntry(name: "../outside.txt", bytes: Data("must stay inside".utf8)).write(to: traversal)
        XCTAssertThrowsError(try AppUpdateInstaller.extractArchive(traversal, to: root.appendingPathComponent("extracted")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
        let links = root.appendingPathComponent("links.zip")
        try zipEntry(name: "App.app/link", bytes: Data("../../outside".utf8), mode: 0o120777).write(to: links)
        XCTAssertThrowsError(try AppUpdateInstaller.extractArchive(links, to: root.appendingPathComponent("extracted-links")))
    }

    func testSafeExtractionPreservesExecutableAndInternalSymlink() throws {
        let container = root.appendingPathComponent("source/Fixture.app")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let content = container.appendingPathComponent("executable")
        try Data("program".utf8).write(to: content); chmod(content.path, 0o755)
        try FileManager.default.createSymbolicLink(atPath: container.appendingPathComponent("alias").path, withDestinationPath: "executable")
        let zip = root.appendingPathComponent("safe.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", container.path, zip.path])
        let destination = root.appendingPathComponent("safe-output")
        try AppUpdateInstaller.extractArchive(zip, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Fixture.app/executable")), Data("program".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Fixture.app/alias").path), "executable")
        let mode = (try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("Fixture.app/executable").path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o111, 0o111)
    }

    func testSignedAppInstallAndRestoreActuallySwapVersions() async throws {
        let fixture = try makeSignedFixture()
        let installer = service()
        let plan = try await installer.prepareLocalArchive(fixture.archive, app: fixture.app, release: fixture.release)
        XCTAssertFalse(plan.requiresSystemInstaller)
        XCTAssertEqual(try version(fixture.app.url), "1")
        let installed = try await installer.install(plan)
        XCTAssertEqual(installed.state, .installed)
        XCTAssertEqual(try version(fixture.app.url), "2")
        XCTAssertEqual(try version(XCTUnwrap(installed.backupURL)), "1")
        let restored = try await installer.restore(plan.id)
        XCTAssertEqual(restored.state, .restored)
        XCTAssertEqual(try version(fixture.app.url), "1")
        XCTAssertEqual(try version(XCTUnwrap(restored.backupURL)), "2")
    }

    func testWrongBundleAndAdvertisedBuildNeverReplaceInstalledApp() async throws {
        let fixture = try makeSignedFixture(newIdentifier: "com.example.other")
        do { _ = try await service().prepareLocalArchive(fixture.archive, app: fixture.app, release: fixture.release); XCTFail("accepted another app") } catch {}
        XCTAssertEqual(try version(fixture.app.url), "1")
        let valid = try makeSignedFixture(folder: "second")
        let wrong = AppUpdateRelease(sourceURL: valid.release.sourceURL, downloadURL: valid.release.downloadURL, version: "3", buildVersion: "3", edSignature: valid.release.edSignature, expectedLength: valid.release.expectedLength)
        do { _ = try await service(storage: "second-storage").prepareLocalArchive(valid.archive, app: valid.app, release: wrong); XCTFail("accepted false build") } catch {}
        XCTAssertEqual(try version(valid.app.url), "1")
    }

    func testRunningApplicationIsNeverForcedToQuit() async throws {
        let fixture = try makeSignedFixture()
        let lifecycle = AppUpdateLifecycle(isRunning: { _ in true }, requestQuit: { _ in false }, relaunch: { _ in })
        let installer = service(lifecycle: lifecycle)
        let plan = try await installer.prepareLocalArchive(fixture.archive, app: fixture.app, release: fixture.release)
        do { _ = try await installer.install(plan); XCTFail("automatic install replaced running app") }
        catch AppUpdateInstallError.appIsRunning {} catch { XCTFail("wrong error: \(error)") }
        do { _ = try await installer.install(plan, quitIfRunning: true); XCTFail("ignored refused quit") }
        catch AppUpdateInstallError.quitRefused {} catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(try version(fixture.app.url), "1")
    }

    func testLaunchFailureRollsBackAndKeepsBothCopies() async throws {
        let fixture = try makeSignedFixture()
        let running = UpdateRunningState()
        let lifecycle = AppUpdateLifecycle(isRunning: { _ in await running.value }, requestQuit: { _ in await running.stop(); return true }, relaunch: { _ in throw AppUpdateInstallError.launchFailed })
        let installer = service(lifecycle: lifecycle)
        let plan = try await installer.prepareLocalArchive(fixture.archive, app: fixture.app, release: fixture.release)
        do { _ = try await installer.install(plan, quitIfRunning: true); XCTFail("ignored failed launch") } catch {}
        XCTAssertEqual(try version(fixture.app.url), "1")
        let records = try await installer.history()
        XCTAssertEqual(records.first?.state, .restored)
        XCTAssertEqual(try version(XCTUnwrap(records.first?.backupURL)), "2")
    }

    func testRestoreRejectsChangedBackup() async throws {
        let fixture = try makeSignedFixture()
        let installer = service()
        let plan = try await installer.prepareLocalArchive(fixture.archive, app: fixture.app, release: fixture.release)
        let installed = try await installer.install(plan)
        let backup = try XCTUnwrap(installed.backupURL)
        try Data("external change".utf8).write(to: backup.appendingPathComponent("Contents/Resources/value.txt"))
        do { _ = try await installer.restore(plan.id); XCTFail("restored changed backup") } catch {}
        XCTAssertEqual(try version(fixture.app.url), "2")
    }

    func testInterruptedSwapReconcilesFromActualSignedApps() async throws {
        let fixture = try makeSignedFixture()
        let installer = service()
        let plan = try await installer.prepareLocalArchive(fixture.archive, app: fixture.app, release: fixture.release)
        _ = try await installer.install(plan)
        let history = root.appendingPathComponent("storage/history.json")
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [[String: Any]])
        objects[0]["state"] = "installing"
        try JSONSerialization.data(withJSONObject: objects).write(to: history)
        let reconciled = try await service().history()
        XCTAssertEqual(reconciled.first?.state, .installed)
        _ = try await service().restore(plan.id)
        XCTAssertEqual(try version(fixture.app.url), "1")
    }

    func testHistoryCorruptionAndSymlinkTargetsFailClosed() async throws {
        let installer = service()
        _ = try await installer.history()
        try Data("broken history".utf8).write(to: root.appendingPathComponent("storage/history.json"))
        do { _ = try await installer.history(); XCTFail("accepted corrupt history") }
        catch AppUpdateInstallError.damagedHistory {} catch { XCTFail("wrong error: \(error)") }
        let target = root.appendingPathComponent("Applications/Target.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Applications/Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let archive = root.appendingPathComponent("fixture.zip"); try Data("archive".utf8).write(to: archive)
        let release = AppUpdateRelease(sourceURL: URL(string: "https://example.com/feed")!, downloadURL: URL(string: "https://example.com/update.zip")!, version: "2", buildVersion: "2")
        let app = AppDescriptor(url: alias, name: "Alias", bundleID: "com.example.fixture", version: "1", buildVersion: "1")
        do { _ = try await service(storage: "new-storage").prepareLocalArchive(archive, app: app, release: release); XCTFail("accepted linked target") } catch {}
    }

    func testAppcastPreservesSignatureAndFiltersIncompatibleReleases() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>999</sparkle:version><sparkle:minimumSystemVersion>999.0</sparkle:minimumSystemVersion><enclosure url="https://example.com/future.zip"/></item>
        <item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString><enclosure url="https://example.com/update.zip" sparkle:edSignature="signed" length="1234"/></item>
        </channel></rss>
        """
        let app = AppDescriptor(url: root, name: "Fixture", bundleID: "com.example.fixture", version: "1", buildVersion: "1")
        let parsed = try AppUpdateChecker.parse(data: Data(xml.utf8), app: app, sourceURL: URL(string: "https://example.com/feed")!)
        XCTAssertEqual(parsed.release?.buildVersion, "2")
        XCTAssertEqual(parsed.release?.edSignature, "signed")
        XCTAssertEqual(parsed.release?.expectedLength, 1234)
    }

    private func service(storage: String = "storage", lifecycle: AppUpdateLifecycle? = nil) -> AppUpdateInstaller {
        AppUpdateInstaller(storageURL: root.appendingPathComponent(storage), applicationRoots: [root.appendingPathComponent("Applications"), root.appendingPathComponent("second/Applications")], lifecycle: lifecycle ?? AppUpdateLifecycle(isRunning: { _ in false }, requestQuit: { _ in true }, relaunch: { _ in }))
    }
    private func makeSignedFixture(folder: String = "", newIdentifier: String = "com.example.orbit-updater-fixture") throws -> (app: AppDescriptor, archive: URL, release: AppUpdateRelease) {
        guard let identity = ProcessInfo.processInfo.environment["ORBIT_TEST_SIGNING_IDENTITY"], !identity.isEmpty else { throw XCTSkip("Set ORBIT_TEST_SIGNING_IDENTITY after explicitly allowing that key for codesign; these tests never request keychain access automatically") }
        let base = folder.isEmpty ? root! : root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("fixture.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let binary = base.appendingPathComponent("Fixture")
        try run("/usr/bin/clang", [source.path, "-o", binary.path])
        let old = try makeApp(base.appendingPathComponent("Applications/Fixture.app"), build: "1", identifier: "com.example.orbit-updater-fixture", binary: binary, identity: identity)
        let new = try makeApp(base.appendingPathComponent("next/Fixture.app"), build: "2", identifier: newIdentifier, binary: binary, identity: identity)
        let archive = base.appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", new.path, archive.path])
        let data = try Data(contentsOf: archive)
        let release = AppUpdateRelease(sourceURL: URL(string: "https://example.com/appcast.xml")!, downloadURL: URL(string: "https://example.com/update.zip")!, version: "2", buildVersion: "2", edSignature: try key.signature(for: data).base64EncodedString(), expectedLength: Int64(data.count))
        return (AppDescriptor(url: old, name: "Fixture", bundleID: "com.example.orbit-updater-fixture", version: "1", buildVersion: "1", appcastURL: release.sourceURL), archive, release)
    }
    private func makeApp(_ url: URL, build: String, identifier: String, binary: URL, identity: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: url.appendingPathComponent("Contents/MacOS/Fixture"))
        let values = ["CFBundleIdentifier": identifier, "CFBundleName": "Fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": build, "CFBundleShortVersionString": build, "LSMinimumSystemVersion": "14.0", "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("version \(build)".utf8).write(to: url.appendingPathComponent("Contents/Resources/value.txt"))
        try run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", url.path])
        return url
    }
    private func version(_ app: URL) throws -> String {
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])
        return try XCTUnwrap(values["CFBundleVersion"] as? String)
    }
    @discardableResult private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AppUpdateInstallError.commandFailed(output) }
        return output
    }
    private func zipEntry(name: String, bytes: Data, mode: UInt32 = 0o100644) -> Data {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
        crc ^= 0xffffffff
        var data = Data()
        func word(_ n: UInt16) { data.append(UInt8(n & 255)); data.append(UInt8(n >> 8)) }
        func dword(_ n: UInt32) { word(UInt16(n & 65535)); word(UInt16(n >> 16)) }
        let encoded = Data(name.utf8)
        dword(0x04034b50); word(20); word(0x800); word(0); word(0); word(0); dword(crc); dword(UInt32(bytes.count)); dword(UInt32(bytes.count)); word(UInt16(encoded.count)); word(0); data.append(encoded); data.append(bytes)
        let offset = UInt32(data.count)
        dword(0x02014b50); word(0x0314); word(20); word(0x800); word(0); word(0); word(0); dword(crc); dword(UInt32(bytes.count)); dword(UInt32(bytes.count)); word(UInt16(encoded.count)); word(0); word(0); word(0); word(0); dword(mode << 16); dword(0); data.append(encoded)
        let size = UInt32(data.count) - offset
        dword(0x06054b50); word(0); word(0); word(1); word(1); dword(size); dword(offset); word(0)
        return data
    }
}

private actor UpdateRunningState {
    var value = true
    func stop() { value = false }
}
