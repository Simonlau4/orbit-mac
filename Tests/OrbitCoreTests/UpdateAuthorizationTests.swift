import XCTest
import Foundation
import Darwin
@testable import OrbitCore

final class UpdateAuthorizationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        let actual = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(actual) }
        root = URL(fileURLWithPath: String(cString: actual)).appendingPathComponent("orbit-update-auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testInvocationExposesOnlyFixedOperationPIDUUIDAndDigest() throws {
        let id = UUID(); let hash = String(repeating: "a", count: 64)
        let value = try UpdateAuthorizationInvocation(transactionID: id, operation: .install, clientPID: getpid(), requestDigest: hash)
        XCTAssertEqual(value.arguments, ["--client", String(getpid()), "--operation", "install", "--transaction", id.uuidString.lowercased(), "--request-digest", hash])
        XCTAssertThrowsError(try UpdateAuthorizationInvocation(transactionID: id, operation: .install, clientPID: 0, requestDigest: hash))
        XCTAssertThrowsError(try UpdateAuthorizationInvocation(transactionID: id, operation: .restore, clientPID: getpid(), requestDigest: "/tmp/source.app"))
    }

    func testRequestRejectsExpiredChangedActionAndEscapingTargets() throws {
        let id = UUID(); let hash = Data(repeating: 1, count: 20).base64EncodedString()
        for leaf in ["../Other.app", "/Applications/App.app", ".Hidden.app", "App.app/Contents", "App\\Other.app"] {
            XCTAssertFalse(UpdateAuthorizationRequest.validLeaf(leaf))
        }
        let request = UpdateAuthorizationRequest(id: id, operation: .install, targetLeaf: "Fixture.app", originalHash: hash, replacementHash: hash, issuedAt: Date(timeIntervalSinceNow: -601))
        XCTAssertThrowsError(try request.validate(id: id, operation: .install))
        let valid = UpdateAuthorizationRequest(id: id, operation: .restore, targetLeaf: "Fixture.app", originalHash: hash, replacementHash: hash, issuedAt: Date())
        try valid.validate(id: id, operation: .restore)
        XCTAssertThrowsError(try valid.validate(id: id, operation: .install))
    }

    func testDescriptorCopyPreservesBytesAndInternalLinksWithoutFollowingExternalLinks() throws {
        let source = try directory("source"); let destination = try directory("destination")
        try Data("content".utf8).write(to: source.appendingPathComponent("value.bin"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("alias").path, withDestinationPath: "value.bin")
        let sourceFD = try UpdateFD.openDirectory(source, owners: [0, getuid()], forbidWritable: true)
        defer { close(sourceFD) }
        let destinationFD = try UpdateFD.openDirectory(destination, owners: [0, getuid()], forbidWritable: true)
        defer { close(destinationFD) }
        var budget = UpdateFD.CopyBudget()
        try UpdateFD.inspectOrCopy(sourceFD, destination: destinationFD, owner: getuid(), rootOwned: false, budget: &budget)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("value.bin")), Data("content".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("alias").path), "value.bin")
        let unsafe = try directory("unsafe"); let output = try directory("unsafe-output")
        try FileManager.default.createSymbolicLink(atPath: unsafe.appendingPathComponent("secret").path, withDestinationPath: "/etc/passwd")
        let input = try UpdateFD.openDirectory(unsafe, owners: [0, getuid()], forbidWritable: true); defer { close(input) }
        let out = try UpdateFD.openDirectory(output, owners: [0, getuid()], forbidWritable: true); defer { close(out) }
        var unsafeBudget = UpdateFD.CopyBudget()
        XCTAssertThrowsError(try UpdateFD.inspectOrCopy(input, destination: out, owner: getuid(), rootOwned: false, budget: &unsafeBudget))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("secret").path))
    }

    func testCopyRejectsHardlinks() throws {
        let source = try directory("source"); let destination = try directory("destination")
        let outside = root.appendingPathComponent("outside.txt"); try Data("original".utf8).write(to: outside)
        XCTAssertEqual(link(outside.path, source.appendingPathComponent("hardlink").path), 0)
        let input = try UpdateFD.openDirectory(source, owners: [0, getuid()], forbidWritable: true); defer { close(input) }
        let output = try UpdateFD.openDirectory(destination, owners: [0, getuid()], forbidWritable: true); defer { close(output) }
        var budget = UpdateFD.CopyBudget()
        XCTAssertThrowsError(try UpdateFD.inspectOrCopy(input, destination: output, owner: getuid(), rootOwned: false, budget: &budget))
        XCTAssertEqual(try String(contentsOf: outside), "original")
    }

    func testPinnedDirectoryWriteSurvivesPathReplacement() throws {
        let original = try directory("pinned"); let moved = root.appendingPathComponent("moved"); let outside = try directory("outside")
        let fd = try UpdateFD.openDirectory(original, owners: [0, getuid()], forbidWritable: true); defer { close(fd) }
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        try UpdateFD.writeFile(fd, name: "journal.json", data: Data("journal".utf8), mode: 0o600)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("journal.json")), "journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("journal.json").path))
    }

    func testPinnedAtomicExchangeAndRestorePreserveRealOldApp() throws {
        let apps = try directory("Applications"); let stage = try directory("root-stage")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Fixture.app"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("replacement.app"), withIntermediateDirectories: false)
        try Data("old".utf8).write(to: apps.appendingPathComponent("Fixture.app/version"))
        try Data("new".utf8).write(to: stage.appendingPathComponent("replacement.app/version"))
        let appsFD = try UpdateFD.openDirectory(apps, owners: [0, getuid()], forbidWritable: true); defer { close(appsFD) }
        let stageFD = try UpdateFD.openDirectory(stage, owners: [0, getuid()], forbidWritable: true); defer { close(stageFD) }
        let original = try UpdateFD.entry(appsFD, "Fixture.app")
        try UpdateFD.swap(appsFD, "Fixture.app", stageFD, "replacement.app")
        XCTAssertEqual(try String(contentsOf: apps.appendingPathComponent("Fixture.app/version")), "new")
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("replacement.app/version")), "old")
        XCTAssertEqual(try UpdateFD.entry(stageFD, "replacement.app").st_ino, original.st_ino)
        try UpdateFD.swap(appsFD, "Fixture.app", stageFD, "replacement.app")
        XCTAssertEqual(try String(contentsOf: apps.appendingPathComponent("Fixture.app/version")), "old")
        XCTAssertEqual(try UpdateFD.entry(appsFD, "Fixture.app").st_ino, original.st_ino)
    }

    func testUnprivilegedFileCannotImpersonateRootReceipt() throws {
        let directory = try directory("receipts"); let path = directory.appendingPathComponent("receipt.json")
        try Data("{}".utf8).write(to: path); chmod(path.path, 0o644)
        let fd = try UpdateFD.openDirectory(directory, owners: [0, getuid()], forbidWritable: true); defer { close(fd) }
        XCTAssertThrowsError(try UpdateFD.readFile(fd, name: "receipt.json", owner: 0, mode: 0o644, maximum: 1024))
    }

    func testNonRootExecutableCannotEnterSystemEngine() async throws {
        guard geteuid() != 0 else { throw XCTSkip("This test checks the non-root rejection") }
        let invocation = try UpdateAuthorizationInvocation(transactionID: UUID(), operation: .install, clientPID: getpid(), requestDigest: String(repeating: "a", count: 64))
        do { _ = try await UpdateAuthorizationAgent.execute(arguments: invocation.arguments); XCTFail("accepted unprivileged agent") }
        catch UpdateAuthorizationError.administratorRequired {} catch { XCTFail("wrong failure: \(error)") }
    }

    func testUserSocketClientCannotReadAuthenticatedRequest() throws {
        let id = UUID(); let data = Data("request held only in client memory".utf8)
        let channel = try UpdateAuthorizationChannel(id: id, bytes: data); defer { channel.close() }
        let invocation = try UpdateAuthorizationInvocation(transactionID: id, operation: .install, clientPID: getpid(), requestDigest: UpdateAuthorizationPaths.digest(data))
        XCTAssertThrowsError(try UpdateAuthorizationChannel.authenticateClient(invocation, uid: getuid()))
    }

    func testOlderInstalledReceiptCannotOverwriteNewRestoreIntent() throws {
        let now = Date(); let digest = String(repeating: "a", count: 64)
        let old = UpdateAuthorizationReceipt(transactionID: UUID(), clientUID: getuid(), targetLeaf: "Fixture.app", identifier: "com.example.fixture",
            originalHash: "old", replacementHash: "new", originalBuild: "1", replacementBuild: "2", state: .installed, message: "installed",
            completedAt: now.addingTimeInterval(-1), requestDigest: digest)
        XCTAssertFalse(old.isCurrent(after: now, requestDigest: digest))
        XCTAssertTrue(old.isCurrent(after: nil, requestDigest: nil))
    }

    func testReceiptMustMatchThisRequestEvenWhenItsTimestampIsRecent() throws {
        let now = Date(); let digest = String(repeating: "a", count: 64)
        let receipt = UpdateAuthorizationReceipt(transactionID: UUID(), clientUID: getuid(), targetLeaf: "Fixture.app", identifier: "com.example.fixture",
            originalHash: "old", replacementHash: "new", originalBuild: "1", replacementBuild: "2", state: .restored, message: "restored",
            completedAt: now.addingTimeInterval(1), requestDigest: digest)
        XCTAssertFalse(receipt.isCurrent(after: now, requestDigest: String(repeating: "b", count: 64)))
        XCTAssertTrue(receipt.isCurrent(after: now, requestDigest: digest))
    }

    func testCreatedDirectoryModeSurvivesRestrictiveUmask() throws {
        let parent = try UpdateFD.openDirectory(root, owners: [0, getuid()], forbidWritable: true)
        defer { close(parent) }
        let previous = umask(0o077); defer { umask(previous) }
        let child = try UpdateFD.childDirectory(parent, name: "public-receipts", owner: getuid(), mode: 0o755, create: true)
        defer { close(child) }
        XCTAssertEqual(try UpdateFD.metadata(child).st_mode & 0o777, 0o755)
    }

    func testRootOwnedApplicationsRouteToExplicitAuthorizationDespiteWritableParent() {
        XCTAssertTrue(AppUpdateInstaller.administratorPolicy(targetOwner: 0, parentWritable: true, directApplications: true))
        XCTAssertFalse(AppUpdateInstaller.administratorPolicy(targetOwner: 501, parentWritable: true, directApplications: true))
        XCTAssertTrue(AppUpdateInstaller.administratorPolicy(targetOwner: 501, parentWritable: false, directApplications: true))
        XCTAssertFalse(AppUpdateInstaller.administratorPolicy(targetOwner: 0, parentWritable: true, directApplications: false))
    }

    func testDirectoryAndReceiptAllowInheritedNonWheelGroup() throws {
        guard getgid() != 0 else { throw XCTSkip("Non-wheel inheritance requires a non-wheel test user") }
        let parent = try UpdateFD.openDirectory(root, owners: [0, getuid()], forbidWritable: true)
        defer { close(parent) }
        let child = try UpdateFD.childDirectory(parent, name: "non-wheel", owner: getuid(), mode: 0o700, create: true)
        defer { close(child) }
        XCTAssertNotEqual(try UpdateFD.metadata(child).st_gid, 0)
        try UpdateFD.writeFile(child, name: "receipt.json", data: Data("receipt".utf8), mode: 0o644)
        let decoded = try UpdateFD.readFile(child, name: "receipt.json", owner: getuid(), mode: 0o644, maximum: 1024)
        XCTAssertEqual(decoded, Data("receipt".utf8))
    }

    @discardableResult private func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}
