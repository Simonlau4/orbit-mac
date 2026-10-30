import Foundation
import AppKit
import Security
import CryptoKit
import Darwin
import CArchive

public enum AppUpdateInstallationState: String, Codable, Sendable {
    case prepared, installing, installed, restoring, restored, failed, handedToSystemInstaller
}

public struct PreparedAppUpdate: Identifiable, Codable, Sendable {
    public let id: UUID
    public let appName: String
    public let appURL: URL
    public let oldVersion: String
    public let newVersion: String
    public let bytes: Int64
    public let requiresSystemInstaller: Bool
    public let requiresAdministrator: Bool
    public let verification: String
    public let originalCodeHash: String?
    public let replacementCodeHash: String?
}

public struct AppUpdateInstallation: Identifiable, Codable, Sendable {
    public let id: UUID
    public let appName: String
    public let appURL: URL
    public let oldVersion: String
    public let newVersion: String
    public var state: AppUpdateInstallationState
    public let createdAt: Date
    public var completedAt: Date?
    public var message: String
    public var backupURL: URL?
    public var authorizationReceipt: UpdateAuthorizationReceipt?
    public var requiresAdministrator: Bool { administratorTransaction == true }
    fileprivate var administratorTransaction: Bool?
    fileprivate var authorizationIntentAt: Date?
    fileprivate var authorizationRequestDigest: String?
    fileprivate var original: UpdateAppIdentity
    fileprivate var replacement: UpdateAppIdentity?
    fileprivate var release: AppUpdateRelease
    fileprivate var archiveDigest: String
    fileprivate var archiveName: String
    fileprivate var candidateRelativePath: String?
    fileprivate var wasRunning: Bool
    fileprivate var packageRelativePath: String?
    fileprivate var packageDigest: String?
}

public struct AppUpdateLifecycle: Sendable {
    public let isRunning: @Sendable (URL) async -> Bool
    public let requestQuit: @Sendable (URL) async -> Bool
    public let relaunch: @Sendable (URL) async throws -> Void

    public init(isRunning: @escaping @Sendable (URL) async -> Bool,
                requestQuit: @escaping @Sendable (URL) async -> Bool,
                relaunch: @escaping @Sendable (URL) async throws -> Void) {
        self.isRunning = isRunning; self.requestQuit = requestQuit; self.relaunch = relaunch
    }

    public static var system: AppUpdateLifecycle {
        AppUpdateLifecycle(isRunning: { url in
            await MainActor.run { NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == url.path && !$0.isTerminated } }
        }, requestQuit: { url in
            let apps = await MainActor.run { NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == url.path && !$0.isTerminated } }
            let accepted = await MainActor.run { apps.allSatisfy { $0.terminate() } }
            guard accepted else { return false }
            for _ in 0..<150 {
                if Task.isCancelled { return false }
                if await MainActor.run(body: { apps.allSatisfy(\.isTerminated) }) { return true }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return false
        }, relaunch: { url in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task { @MainActor in
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    configuration.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                        if let error { continuation.resume(throwing: error) }
                        else if app?.bundleURL?.path == url.path { continuation.resume() }
                        else { continuation.resume(throwing: AppUpdateInstallError.launchFailed) }
                    }
                }
            }
        })
    }
}

public enum AppUpdateInstallError: LocalizedError {
    case unsupported, invalidTarget, busy, noUpdate, invalidMetadata, invalidSignature, identityMismatch
    case incompatible, unsafeArchive, archiveTooLarge, appIsRunning, quitRefused, administratorRequired
    case changed, damagedHistory, invalidState, requiresSystemInstaller, commandFailed(String), launchFailed
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "该更新格式或签名方式不支持安全自动替换。"
        case .invalidTarget: return "只能更新应用目录中有开发者签名的非系统应用。"
        case .busy: return "另一项更新操作正在进行。"
        case .noUpdate: return "没有可安装的新版本。"
        case .invalidMetadata: return "更新包的版本、大小或更新源不符合预期。"
        case .invalidSignature: return "下载签名或应用代码签名无效；已保留原应用。"
        case .identityMismatch: return "新旧应用的标识或开发者不一致；已保留原应用。"
        case .incompatible: return "此更新不兼容当前 macOS 或处理器架构。"
        case .unsafeArchive: return "安装包包含越界路径、特殊文件或不安全链接。"
        case .archiveTooLarge: return "安装包超出大小、条目数或可用空间限制。"
        case .appIsRunning: return "应用仍在运行；自动更新会等它退出后再安装。"
        case .quitRefused: return "应用尚未退出，请保存工作并退出后重试。Orbit 不会强制结束进程。"
        case .administratorRequired: return "此应用目录需要管理员授权；已验证的更新包已保留。"
        case .changed: return "应用或恢复副本已变化；停止替换以保留现有内容。"
        case .damagedHistory: return "更新记录无法读取；停止安装，避免失去恢复副本。"
        case .invalidState: return "该更新不处于可执行的状态。"
        case .requiresSystemInstaller: return "此更新使用系统安装器，需要单独授权；其脚本和系统文件不支持 Orbit 自动回滚。"
        case .commandFailed(let message): return "安装步骤失败：\(message)"
        case .launchFailed: return "新版本未能启动。"
        }
    }
}

/// Updates are opt-in. A prepared download never changes the installed application.
/// Only fixed system tools run; downloaded executables and installer scripts never run during preparation.
public actor AppUpdateInstaller {
    private let storage: URL
    private let applicationRoots: [URL]
    private let lifecycle: AppUpdateLifecycle
    private let fm = FileManager.default
    private var inFlight = false
    private let maximumArchiveBytes: Int64 = 2_147_483_648

    public init(storageURL: URL? = nil, applicationRoots: [URL]? = nil, lifecycle: AppUpdateLifecycle = .system) {
        self.storage = storageURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit/Updates")
        self.applicationRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        self.lifecycle = lifecycle
    }

    public func prepare(_ app: AppDescriptor, update: AppUpdateResult) async throws -> PreparedAppUpdate {
        guard update.state == .updateAvailable, let release = update.release else { throw AppUpdateInstallError.noUpdate }
        return try await prepareArchive(app: app, release: release, localArchive: nil)
    }

    /// Offline deployments use the same signing, target, version and extraction checks as downloads.
    public func prepareLocalArchive(_ archive: URL, app: AppDescriptor, release: AppUpdateRelease) async throws -> PreparedAppUpdate {
        try await prepareArchive(app: app, release: release, localArchive: archive)
    }

    private func prepareArchive(app: AppDescriptor, release: AppUpdateRelease, localArchive: URL?) async throws -> PreparedAppUpdate {
        let lock = try beginOperation(); defer { endOperation(lock) }
        try validateTarget(app.url)
        let original = try UpdateAppIdentity.read(app.url)
        guard original.identifier == app.bundleID, original.build == app.buildVersion || app.buildVersion.isEmpty,
              !original.identifier.hasPrefix("com.apple."), original.identifier != Bundle.main.bundleIdentifier else { throw AppUpdateInstallError.invalidTarget }
        let info = try Self.info(app.url)
        guard let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)) else { throw AppUpdateInstallError.invalidMetadata }
        try AppUpdateChecker.validateFeedURL(feed)
        try AppUpdateChecker.validateFeedURL(release.sourceURL)
        try AppUpdateChecker.validateFeedURL(release.downloadURL, resolveHost: localArchive == nil)
        guard release.buildVersion.compare(original.build, options: .numeric) == .orderedDescending,
              release.expectedLength.map({ $0 > 0 && $0 <= maximumArchiveBytes }) ?? true else { throw AppUpdateInstallError.invalidMetadata }
        try Self.checkCompatibility(minimum: release.minimumSystemVersion, maximum: release.maximumSystemVersion, architectures: release.architectures)
        let ext = release.downloadURL.pathExtension.lowercased()
        guard ["zip", "dmg", "pkg", "mpkg"].contains(ext) else { throw AppUpdateInstallError.unsupported }
        let id = UUID(); let folder = transactionFolder(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: folder) } }
        let archive = folder.appendingPathComponent("download." + ext)
        if let localArchive {
            try UpdatePaths.noLinks(localArchive)
            let attributes = try fm.attributesOfItem(atPath: localArchive.path)
            guard localArchive.pathExtension.lowercased() == ext,
                  (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= maximumArchiveBytes else { throw AppUpdateInstallError.archiveTooLarge }
            try fm.copyItem(at: localArchive, to: archive)
        } else { try await download(release, to: archive) }
        try Self.verifyArchive(archive, signature: release.edSignature, publicKey: info["SUPublicEDKey"] as? String, expectedLength: release.expectedLength)
        let digest = try Self.digest(archive)
        let package = ["pkg", "mpkg"].contains(ext) || release.installationType != "application"
        var candidate: URL?; var packageURL: URL?
        if package {
            guard info["SUPublicEDKey"] as? String != nil else { throw AppUpdateInstallError.invalidSignature }
            if ["pkg", "mpkg"].contains(ext) { packageURL = archive }
            else if ext == "zip" {
                let extracted = folder.appendingPathComponent("extracted", isDirectory: true)
                try Self.extractArchive(archive, to: extracted); packageURL = try Self.findPackage(in: extracted)
            } else { packageURL = try await extractDiskImage(archive, in: folder, identifier: original.identifier, package: true) }
            try await verifyPackagePublisher(packageURL!, team: original.team)
        } else if ext == "zip" {
            let extracted = folder.appendingPathComponent("extracted", isDirectory: true)
            try Self.extractArchive(archive, to: extracted); candidate = try Self.findApp(in: extracted, identifier: original.identifier)
        } else { candidate = try await extractDiskImage(archive, in: folder, identifier: original.identifier) }
        let replacement: UpdateAppIdentity?
        if let candidate {
            try Self.validateApplicationTree(candidate)
            replacement = try UpdateAppIdentity.read(candidate, matching: original.requirement)
            guard replacement?.identifier == original.identifier, replacement?.team == original.team,
                  replacement?.build == release.buildVersion else { throw AppUpdateInstallError.identityMismatch }
            let newInfo = try Self.info(candidate)
            try Self.checkCompatibility(minimum: newInfo["LSMinimumSystemVersion"] as? String, maximum: nil, architectures: [])
            try await checkExecutableArchitecture(candidate, info: newInfo)
            if original.developerID { try await command("/usr/sbin/spctl", ["--assess", "--type", "execute", candidate.path], timeout: 90) }
        } else { replacement = nil }
        try verifyUnchanged(app.url, expected: original, exactLocation: true)
        var record = AppUpdateInstallation(id: id, appName: app.name, appURL: app.url, oldVersion: app.version,
                                          newVersion: release.version, state: .prepared, createdAt: Date(),
                                          message: package ? "已验证包签名；需系统安装器授权。" : "下载和签名已验证，原应用尚未更改。",
                                          original: original, replacement: replacement, release: release,
                                          archiveDigest: digest, archiveName: archive.lastPathComponent,
                                          candidateRelativePath: candidate.map { String($0.path.dropFirst(folder.path.count + 1)) }, wasRunning: false)
        record.packageRelativePath = packageURL.map { String($0.path.dropFirst(folder.path.count + 1)) }
        record.packageDigest = try packageURL.map(Self.digest)
        let result = try plan(record)
        var records = try load(); records.append(record); try save(records)
        prepared = true; return result
    }

    /// Automatic policy should pass quitIfRunning=false; this method never force-quits applications.
    public func install(_ prepared: PreparedAppUpdate, quitIfRunning: Bool = false,
                        relaunchIfPreviouslyRunning: Bool = true) async throws -> AppUpdateInstallation {
        let lock = try beginOperation(); defer { endOperation(lock) }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == prepared.id }), records[index].state == .prepared else { throw AppUpdateInstallError.invalidState }
        var record = records[index]
        try bindPrepared(prepared, to: record)
        try validateRecordPaths(record)
        guard let relative = record.candidateRelativePath, let replacement = record.replacement else { throw AppUpdateInstallError.requiresSystemInstaller }
        try verifyUnchanged(record.appURL, expected: record.original, exactLocation: true)
        let staged = transactionFolder(record.id).appendingPathComponent(relative)
        try verifyUnchanged(staged, expected: replacement)
        guard !Self.requiresAdministrator(at: record.appURL) else { throw AppUpdateInstallError.administratorRequired }
        record.wasRunning = await lifecycle.isRunning(record.appURL)
        if record.wasRunning {
            guard quitIfRunning else { throw AppUpdateInstallError.appIsRunning }
            guard await lifecycle.requestQuit(record.appURL), !(await lifecycle.isRunning(record.appURL)) else { throw AppUpdateInstallError.quitRefused }
        }
        try Task.checkCancellation()
        try verifyUnchanged(record.appURL, expected: record.original, exactLocation: true)
        let sibling = backupURL(record)
        guard !fm.fileExists(atPath: sibling.path) else { throw AppUpdateInstallError.changed }
        try fm.createDirectory(at: sibling, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try await command("/usr/bin/ditto", ["--rsrc", "--extattr", staged.path, sibling.path], timeout: 180)
            try verifyUnchanged(sibling, expected: replacement)
            try Task.checkCancellation()
            guard !(await lifecycle.isRunning(record.appURL)) else { throw AppUpdateInstallError.appIsRunning }
            try verifyUnchanged(record.appURL, expected: record.original, exactLocation: true)
            try verifyUnchanged(sibling, expected: replacement)
        } catch {
            // Only our uncommitted copy is removed. Original user data is never removed here.
            try? fm.removeItem(at: sibling)
            throw error
        }
        record.backupURL = sibling; record.state = .installing; record.message = "正在原子替换应用，旧版本将保留。"
        records[index] = record; try save(records)
        try Self.swap(record.appURL, sibling)
        do {
            try verifyUnchanged(record.appURL, expected: replacement)
            try verifyUnchanged(sibling, expected: record.original)
            record.state = .installed; record.completedAt = Date(); record.message = "已安装 \(record.newVersion)，旧版本可恢复。"
            records[index] = record; try save(records)
            if record.wasRunning && relaunchIfPreviouslyRunning { try await lifecycle.relaunch(record.appURL) }
            return record
        } catch {
            try verifyUnchanged(record.appURL, expected: replacement)
            try verifyUnchanged(sibling, expected: record.original)
            try Self.swap(record.appURL, sibling)
            record.state = .restored; record.completedAt = Date(); record.message = "新版本验证或启动失败，已恢复旧版本。"
            records[index] = record; try save(records)
            if record.wasRunning { try? await lifecycle.relaunch(record.appURL) }
            throw error
        }
    }

    /// Explicit macOS authentication only. Automatic update policies must continue using install().
    public func installAuthorized(_ prepared: PreparedAppUpdate, runner: @escaping UpdateAuthorizationRunner,
                                  quitIfRunning: Bool = true, relaunchIfPreviouslyRunning: Bool = true) async throws -> AppUpdateInstallation {
        // A failed ordinary rename leaves a journal intent; reconcile it before explicit elevation.
        _ = try history()
        let lock = try beginOperation(); defer { endOperation(lock) }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == prepared.id }),
              records[index].state == .prepared || (records[index].requiresAdministrator && records[index].state == .installing),
              records[index].candidateRelativePath != nil else { throw AppUpdateInstallError.invalidState }
        var record = records[index]
        try bindPrepared(prepared, to: record)
        guard prepared.originalCodeHash != nil, prepared.replacementCodeHash != nil else { throw UpdateAuthorizationError.invalidRequest }
        try validateRecordPaths(record, requirePreparedPayload: record.state == .prepared)
        if let receipt = try UpdateAuthorizationReceipt.read(record.id), authorizationReceiptIsCurrent(receipt, record: record) {
            try applyAuthorization(receipt, to: &record)
            if [.installed, .restored].contains(record.state) { records[index] = record; try save(records); return record }
        }
        guard record.appURL.deletingLastPathComponent().path == "/Applications" else { throw UpdateAuthorizationError.unsupportedTarget }
        record.wasRunning = await lifecycle.isRunning(record.appURL)
        if record.wasRunning {
            guard quitIfRunning else { throw AppUpdateInstallError.appIsRunning }
            guard await lifecycle.requestQuit(record.appURL), !(await lifecycle.isRunning(record.appURL)) else { throw AppUpdateInstallError.quitRefused }
        }
        record.administratorTransaction = true
        try await performAuthorization(.install, record: &record, records: &records, index: index, runner: runner)
        if record.state == .installed, record.wasRunning && relaunchIfPreviouslyRunning {
            do { try await lifecycle.relaunch(record.appURL) }
            catch {
                // Rollback executes in the same explicit workflow; the root component never launches an app.
                try? await performAuthorization(.restore, record: &record, records: &records, index: index, runner: runner)
                if record.state == .restored { try? await lifecycle.relaunch(record.appURL) }
                throw AppUpdateInstallError.launchFailed
            }
        }
        return record
    }

    public func restoreAuthorized(_ id: UUID, runner: @escaping UpdateAuthorizationRunner,
                                  quitIfRunning: Bool = true) async throws -> AppUpdateInstallation {
        let lock = try beginOperation(); defer { endOperation(lock) }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].requiresAdministrator else { throw AppUpdateInstallError.invalidState }
        var record = records[index]
        try validateRecordPaths(record, requirePreparedPayload: false)
        if let receipt = try UpdateAuthorizationReceipt.read(id), authorizationReceiptIsCurrent(receipt, record: record) { try applyAuthorization(receipt, to: &record) }
        if record.state == .restored { records[index] = record; try save(records); return record }
        guard [.installed, .restoring, .installing].contains(record.state) else { throw AppUpdateInstallError.invalidState }
        let running = await lifecycle.isRunning(record.appURL)
        if running {
            guard quitIfRunning else { throw AppUpdateInstallError.appIsRunning }
            guard await lifecycle.requestQuit(record.appURL), !(await lifecycle.isRunning(record.appURL)) else { throw AppUpdateInstallError.quitRefused }
        }
        try await performAuthorization(.restore, record: &record, records: &records, index: index, runner: runner)
        if record.state == .restored, running { try await lifecycle.relaunch(record.appURL) }
        return record
    }

    private func performAuthorization(_ operation: UpdateAuthorizationOperation, record: inout AppUpdateInstallation,
                                      records: inout [AppUpdateInstallation], index: Int,
                                      runner: @escaping UpdateAuthorizationRunner) async throws {
        let previousState = record.state
        let (invocation, channel) = try authorizationRequest(record: record, operation: operation)
        defer { channel.close() }
        record.authorizationIntentAt = Date(); record.authorizationRequestDigest = invocation.requestDigest
        record.administratorTransaction = true
        record.state = operation == .install ? .installing : .restoring
        record.message = "正在等待 macOS 认证与管理员更新回执。"
        records[index] = record; try save(records)
        do {
            try await runner(invocation)
            guard let receipt = try UpdateAuthorizationReceipt.read(record.id), authorizationReceiptIsCurrent(receipt, record: record) else { throw UpdateAuthorizationError.receiptUnavailable }
            try applyAuthorization(receipt, to: &record)
            records[index] = record; try save(records)
            guard [.installed, .restored].contains(record.state) else { throw UpdateAuthorizationError.invalidState }
        } catch {
            if let receipt = try? UpdateAuthorizationReceipt.read(record.id), authorizationReceiptIsCurrent(receipt, record: record) { try? applyAuthorization(receipt, to: &record) }
            else if let authError = error as? UpdateAuthorizationError, case .cancelled = authError {
                record.state = previousState; record.message = "管理员认证已取消。"
                if ![.installing, .restoring].contains(previousState) { record.authorizationIntentAt = nil; record.authorizationRequestDigest = nil }
            } else { record.message = "授权操作未取得最终回执，请继续安装或认证恢复以核对实际状态。" }
            records[index] = record; try save(records); throw error
        }
    }

    private func authorizationRequest(record: AppUpdateInstallation, operation: UpdateAuthorizationOperation) throws -> (UpdateAuthorizationInvocation, UpdateAuthorizationChannel) {
        guard getuid() > 0, record.appURL.deletingLastPathComponent().path == "/Applications",
              UpdateAuthorizationRequest.validLeaf(record.appURL.lastPathComponent), let replacement = record.replacement else { throw UpdateAuthorizationError.unsupportedTarget }
        let requests = UpdateAuthorizationPaths.requests(home: fm.homeDirectoryForCurrentUser)
        var existing = requests
        while !fm.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        try UpdatePaths.noLinks(existing)
        try fm.createDirectory(at: requests, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = try UpdateFD.openDirectory(requests, owners: [0, getuid()], forbidWritable: true)
        defer { close(parent) }
        let inbox = try UpdateFD.childDirectory(parent, name: record.id.uuidString.lowercased(), owner: getuid(), mode: 0o700, create: true)
        defer { close(inbox) }
        if operation == .install, let relative = record.candidateRelativePath {
            let sourceURL = transactionFolder(record.id).appendingPathComponent(relative)
            if fm.fileExists(atPath: sourceURL.path) {
                try verifyUnchanged(sourceURL, expected: replacement)
                let source = try UpdateFD.openDirectory(sourceURL, owners: [0, getuid()], forbidWritable: true)
                defer { close(source) }
                if UpdateFD.exists(inbox, "payload.app") { try UpdateFD.removeOwnTree(inbox, name: "payload.app", owner: getuid()) }
                guard mkdirat(inbox, "payload.app", 0o755) == 0 else { throw UpdateFD.failure() }
                let destination = try UpdateFD.childDirectory(inbox, name: "payload.app", owner: getuid())
                defer { close(destination) }
                var budget = UpdateFD.CopyBudget()
                try UpdateFD.inspectOrCopy(source, destination: destination, owner: getuid(), rootOwned: false, budget: &budget)
            } else if record.state == .prepared { throw UpdateAuthorizationError.sourceChanged }
        }
        let request = UpdateAuthorizationRequest(id: record.id, operation: operation, targetLeaf: record.appURL.lastPathComponent,
            originalHash: record.original.codeHash, replacementHash: replacement.codeHash, issuedAt: Date())
        let data = try JSONEncoder().encode(request)
        try UpdateFD.writeFile(inbox, name: "request.json", data: data, mode: 0o600)
        let invocation = try UpdateAuthorizationInvocation(transactionID: record.id, operation: operation, clientPID: getpid(), requestDigest: UpdateAuthorizationPaths.digest(data))
        return (invocation, try UpdateAuthorizationChannel(id: record.id, bytes: data))
    }

    private func authorizationReceiptIsCurrent(_ receipt: UpdateAuthorizationReceipt, record: AppUpdateInstallation) -> Bool {
        receipt.isCurrent(after: record.authorizationIntentAt, requestDigest: record.authorizationRequestDigest)
    }

    private func bindPrepared(_ prepared: PreparedAppUpdate, to record: AppUpdateInstallation) throws {
        guard prepared.id == record.id, prepared.appURL == record.appURL, prepared.oldVersion == record.oldVersion,
              prepared.newVersion == record.newVersion,
              prepared.originalCodeHash.map({ $0 == record.original.codeHash }) ?? true,
              prepared.replacementCodeHash.map({ $0 == record.replacement?.codeHash }) ?? true else { throw UpdateAuthorizationError.sourceChanged }
    }

    private func applyAuthorization(_ receipt: UpdateAuthorizationReceipt, to record: inout AppUpdateInstallation) throws {
        guard receipt.transactionID == record.id, receipt.clientUID == getuid(),
              record.appURL.path == "/Applications/" + receipt.targetLeaf, receipt.identifier == record.original.identifier,
              receipt.originalHash == record.original.codeHash, receipt.replacementHash == record.replacement?.codeHash else { throw UpdateAuthorizationError.invalidRequest }
        if receipt.state == .installed, let replacement = record.replacement { try verifyUnchanged(record.appURL, expected: replacement) }
        if receipt.state == .restored { try verifyUnchanged(record.appURL, expected: record.original) }
        record.administratorTransaction = true; record.authorizationReceipt = receipt
        record.state = receipt.state; record.completedAt = receipt.completedAt; record.message = receipt.message
        record.authorizationIntentAt = nil; record.authorizationRequestDigest = nil
        if [.installed, .restored].contains(receipt.state) { record.backupURL = receipt.backupURL }
    }

    public func restore(_ id: UUID, quitIfRunning: Bool = false) async throws -> AppUpdateInstallation {
        let lock = try beginOperation(); defer { endOperation(lock) }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .installed,
              let replacement = records[index].replacement else { throw AppUpdateInstallError.invalidState }
        var record = records[index]
        guard !record.requiresAdministrator else { throw AppUpdateInstallError.administratorRequired }
        try validateRecordPaths(record)
        let backup = backupURL(record)
        try verifyUnchanged(record.appURL, expected: replacement)
        try verifyUnchanged(backup, expected: record.original)
        let running = await lifecycle.isRunning(record.appURL)
        if running {
            guard quitIfRunning else { throw AppUpdateInstallError.appIsRunning }
            guard await lifecycle.requestQuit(record.appURL), !(await lifecycle.isRunning(record.appURL)) else { throw AppUpdateInstallError.quitRefused }
        }
        try Task.checkCancellation()
        try verifyUnchanged(record.appURL, expected: replacement)
        try verifyUnchanged(backup, expected: record.original)
        record.state = .restoring; records[index] = record; try save(records)
        try Self.swap(record.appURL, backup)
        try verifyUnchanged(record.appURL, expected: record.original)
        record.state = .restored; record.completedAt = Date(); record.message = "已恢复 \(record.oldVersion)，替换下来的版本仍保留。"
        records[index] = record; try save(records)
        if running { try await lifecycle.relaunch(record.appURL) }
        return record
    }

    /// Explicit action only: package scripts can change files outside the app and cannot be rolled back by Orbit.
    public func openSystemInstaller(_ prepared: PreparedAppUpdate) async throws -> AppUpdateInstallation {
        let lock = try beginOperation(); defer { endOperation(lock) }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == prepared.id }), records[index].state == .prepared,
              records[index].candidateRelativePath == nil else { throw AppUpdateInstallError.invalidState }
        var record = records[index]; try validateRecordPaths(record)
        try verifyUnchanged(record.appURL, expected: record.original, exactLocation: true)
        let archive = transactionFolder(record.id).appendingPathComponent(record.archiveName)
        guard try Self.digest(archive) == record.archiveDigest else { throw AppUpdateInstallError.changed }
        guard let relative = record.packageRelativePath, let expectedDigest = record.packageDigest else { throw AppUpdateInstallError.damagedHistory }
        let package = transactionFolder(record.id).appendingPathComponent(relative)
        guard try Self.digest(package) == expectedDigest else { throw AppUpdateInstallError.changed }
        try await verifyPackagePublisher(package, team: record.original.team)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                NSWorkspace.shared.open([package], withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app"), configuration: NSWorkspace.OpenConfiguration()) { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if app != nil { continuation.resume() }
                    else { continuation.resume(throwing: AppUpdateInstallError.launchFailed) }
                }
            }
        }
        record.state = .handedToSystemInstaller
        record.message = "已交给系统安装器。安装结果由安装器报告，Orbit 不声明已安装或可自动回滚。"
        records[index] = record; try save(records); return record
    }

    public func preparedUpdate(_ id: UUID) throws -> PreparedAppUpdate {
        let lock = try beginOperation(); defer { endOperation(lock) }
        guard let record = try load().first(where: { $0.id == id }), record.state == .prepared || (record.requiresAdministrator && record.state == .installing) else { throw AppUpdateInstallError.invalidState }
        try validateRecordPaths(record, requirePreparedPayload: record.state == .prepared); return try plan(record)
    }

    public func history() throws -> [AppUpdateInstallation] {
        let lock = try beginOperation(); defer { endOperation(lock) }
        var records = try load()
        var changed = false
        for index in records.indices where records[index].requiresAdministrator {
            if let receipt = try UpdateAuthorizationReceipt.read(records[index].id), authorizationReceiptIsCurrent(receipt, record: records[index]) {
                try applyAuthorization(receipt, to: &records[index]); changed = true
            }
        }
        for index in records.indices where !records[index].requiresAdministrator && [.installing, .restoring].contains(records[index].state) {
            let record = records[index]
            try validateRecordPaths(record)
            let target = try? UpdateAppIdentity.read(record.appURL)
            let backup = try? UpdateAppIdentity.read(backupURL(record))
            if target?.codeHash == record.replacement?.codeHash, backup?.codeHash == record.original.codeHash {
                records[index].state = .installed; records[index].message = "已核对中断前的替换，旧版本可恢复。"
            } else if target?.codeHash == record.original.codeHash, backup?.codeHash == record.replacement?.codeHash {
                records[index].state = record.state == .restoring ? .restored : .prepared
                records[index].message = "已核对中断状态，原应用完整。"
                if record.state == .installing {
                    // It is our verified uncommitted staging copy, never a user app.
                    try fm.removeItem(at: backupURL(record)); records[index].backupURL = nil
                }
            } else {
                records[index].state = .failed; records[index].message = "中断后的应用状态无法确认，保留所有副本，未自动覆盖。"
            }
            changed = true
        }
        if changed { try save(records) }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    private func plan(_ record: AppUpdateInstallation) throws -> PreparedAppUpdate {
        let archive = transactionFolder(record.id).appendingPathComponent(record.archiveName)
        let bytes = (try fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        return PreparedAppUpdate(id: record.id, appName: record.appName, appURL: record.appURL,
                                 oldVersion: record.oldVersion, newVersion: record.newVersion, bytes: bytes,
                                 requiresSystemInstaller: record.candidateRelativePath == nil,
                                 requiresAdministrator: Self.requiresAdministrator(at: record.appURL),
                                 verification: record.candidateRelativePath == nil ? "Ed25519 与安装包开发者签名通过" : "下载完整性、代码签名、应用标识、开发者与处理器架构通过",
                                 originalCodeHash: record.original.codeHash, replacementCodeHash: record.replacement?.codeHash)
    }

    static func administratorPolicy(targetOwner: uid_t?, parentWritable: Bool, directApplications: Bool) -> Bool {
        !parentWritable || (directApplications && targetOwner == 0)
    }

    private static func requiresAdministrator(at app: URL) -> Bool {
        var metadata = stat()
        let owner = lstat(app.path, &metadata) == 0 ? metadata.st_uid : nil
        return administratorPolicy(targetOwner: owner,
            parentWritable: FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
            directApplications: app.deletingLastPathComponent().path == "/Applications")
    }

    private func validateTarget(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "app", url.pathComponents.allSatisfy({ $0 != ".." && $0 != "." }),
              applicationRoots.contains(where: { url.path.hasPrefix($0.path + "/") }),
              !url.path.hasPrefix("/System/"), url.path != Bundle.main.bundleURL.path else { throw AppUpdateInstallError.invalidTarget }
        try UpdatePaths.noLinks(url)
        let metadata = try fm.attributesOfItem(atPath: url.path)
        guard metadata[.type] as? FileAttributeType == .typeDirectory else { throw AppUpdateInstallError.invalidTarget }
    }

    private func validateRecordPaths(_ record: AppUpdateInstallation, requirePreparedPayload: Bool = true) throws {
        try validateTarget(record.appURL)
        guard !record.original.identifier.hasPrefix("com.apple."), record.original.identifier != Bundle.main.bundleIdentifier else { throw AppUpdateInstallError.invalidTarget }
        guard record.archiveName == "download." + record.release.downloadURL.pathExtension.lowercased(),
              !record.archiveName.contains("/"), record.backupURL == nil || record.backupURL?.path == (record.requiresAdministrator ? UpdateAuthorizationPaths.transactions.appendingPathComponent(record.id.uuidString.lowercased()).appendingPathComponent("backup.app") : backupURL(record)).path else { throw AppUpdateInstallError.damagedHistory }
        for relative in [record.candidateRelativePath, record.packageRelativePath].compactMap({ $0 }) {
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("\\") else { throw AppUpdateInstallError.damagedHistory }
            if requirePreparedPayload { try UpdatePaths.noLinks(transactionFolder(record.id).appendingPathComponent(relative)) }
        }
        guard record.candidateRelativePath.map({ $0.hasSuffix(".app") }) ?? true,
              record.packageRelativePath.map({ $0.hasSuffix(".pkg") || $0.hasSuffix(".mpkg") }) ?? true,
              record.candidateRelativePath == nil || record.packageRelativePath == nil else { throw AppUpdateInstallError.damagedHistory }
    }

    private func backupURL(_ record: AppUpdateInstallation) -> URL {
        record.appURL.deletingLastPathComponent().appendingPathComponent(".OrbitBackup-" + record.id.uuidString + ".app")
    }
    private func transactionFolder(_ id: UUID) -> URL { storage.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func verifyUnchanged(_ url: URL, expected: UpdateAppIdentity, exactLocation: Bool = false) throws {
        let actual: UpdateAppIdentity
        do { actual = try UpdateAppIdentity.read(url, matching: expected.requirement) }
        catch { throw AppUpdateInstallError.changed }
        guard actual.identifier == expected.identifier, actual.team == expected.team,
              actual.codeHash == expected.codeHash, actual.build == expected.build,
              !exactLocation || (actual.device == expected.device && actual.inode == expected.inode) else { throw AppUpdateInstallError.changed }
    }

    private func beginOperation() throws -> Int32 {
        guard !inFlight else { throw AppUpdateInstallError.busy }
        var existing = storage
        while !fm.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        try UpdatePaths.noLinks(existing)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try UpdatePaths.noLinks(storage)
        let descriptor = open(storage.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppUpdateInstallError.damagedHistory }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw AppUpdateInstallError.busy }
        inFlight = true; return descriptor
    }
    private func endOperation(_ descriptor: Int32) { inFlight = false; flock(descriptor, LOCK_UN); close(descriptor) }
    private func load() throws -> [AppUpdateInstallation] {
        let url = storage.appendingPathComponent("history.json")
        guard fm.fileExists(atPath: url.path) else { return [] }
        try UpdatePaths.noLinks(url)
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 8_388_608 else { throw AppUpdateInstallError.damagedHistory }
            return try JSONDecoder().decode([AppUpdateInstallation].self, from: data)
        } catch { throw AppUpdateInstallError.damagedHistory }
    }
    private func save(_ records: [AppUpdateInstallation]) throws {
        let url = storage.appendingPathComponent("history.json")
        if fm.fileExists(atPath: url.path) { try UpdatePaths.noLinks(url) }
        try JSONEncoder().encode(records).write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { fsync(fd); close(fd) }
        let directory = open(storage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory >= 0 { fsync(directory); close(directory) }
    }

    private func download(_ release: AppUpdateRelease, to target: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: UpdateDownloadRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= maximumArchiveBytes else { throw AppUpdateInstallError.invalidMetadata }
        if let length = release.expectedLength, response.expectedContentLength > 0, response.expectedContentLength != length { throw AppUpdateInstallError.invalidMetadata }
        guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppUpdateInstallError.commandFailed("无法创建下载文件") }
        let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
        var total: Int64 = 0; var buffer = Data(); buffer.reserveCapacity(65_536)
        for try await byte in bytes {
            try Task.checkCancellation(); buffer.append(byte); total += 1
            guard total <= maximumArchiveBytes, release.expectedLength.map({ total <= $0 }) ?? true else { throw AppUpdateInstallError.archiveTooLarge }
            if buffer.count == 65_536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
        guard total > 0, release.expectedLength.map({ total == $0 }) ?? true else { throw AppUpdateInstallError.invalidMetadata }
    }

    public static func verifyArchive(_ archive: URL, signature: String?, publicKey: String?, expectedLength: Int64?) throws {
        try UpdatePaths.noLinks(archive)
        var metadata = stat()
        guard lstat(archive.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_size > 0, metadata.st_size <= 2_147_483_648,
              expectedLength.map({ $0 == metadata.st_size }) ?? true else { throw AppUpdateInstallError.invalidMetadata }
        guard let publicKey else { return } // The extracted app must still satisfy the old app's developer requirement.
        guard let key = Data(base64Encoded: publicKey), key.count == 32,
              let signature = signature.flatMap({ Data(base64Encoded: $0) }), signature.count == 64,
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              verifier.isValidSignature(signature, for: try Data(contentsOf: archive, options: [.mappedIfSafe])) else { throw AppUpdateInstallError.invalidSignature }
    }

    private static func digest(_ url: URL) throws -> String {
        try UpdatePaths.noLinks(url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func info(_ app: URL) throws -> [String: Any] {
        let url = app.appendingPathComponent("Contents/Info.plist")
        try UpdatePaths.noLinks(url)
        guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any] else { throw AppUpdateInstallError.invalidTarget }
        return values
    }

    private static func checkCompatibility(minimum: String?, maximum: String?, architectures: [String]) throws {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        guard minimum.map({ current.compare($0, options: .numeric) != .orderedAscending }) ?? true,
              maximum.map({ current.compare($0, options: .numeric) != .orderedDescending }) ?? true,
              architectures.isEmpty || architectures.contains(arch) || architectures.contains("universal") else { throw AppUpdateInstallError.incompatible }
    }

    private func checkExecutableArchitecture(_ app: URL, info: [String: Any]) async throws {
        guard let executable = info["CFBundleExecutable"] as? String, !executable.contains("/"), !executable.isEmpty else { throw AppUpdateInstallError.invalidTarget }
        let path = app.appendingPathComponent("Contents/MacOS/" + executable)
        try UpdatePaths.noLinks(path)
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/lipo", arguments: ["-archs", path.path], timeoutSeconds: 10))
        guard result.exitCode == 0, !result.timedOut, !result.cancelled else { throw AppUpdateInstallError.incompatible }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard result.output.split(whereSeparator: \.isWhitespace).contains(Substring(architecture)) else { throw AppUpdateInstallError.incompatible }
        let perArchitecture = info["LSMinimumSystemVersionByArchitecture"] as? [String: String]
        try Self.checkCompatibility(minimum: perArchitecture?[architecture], maximum: nil, architectures: [])
    }

    private func command(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws {
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: path, arguments: arguments, timeoutSeconds: timeout))
        if result.cancelled { throw CancellationError() }
        guard result.exitCode == 0, !result.timedOut else { throw AppUpdateInstallError.commandFailed(String(result.output.prefix(1024))) }
    }

    private func verifyPackagePublisher(_ archive: URL, team: String) async throws {
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/sbin/pkgutil", arguments: ["--check-signature", archive.path], timeoutSeconds: 30))
        guard result.exitCode == 0, !result.cancelled, !result.timedOut,
              result.output.contains("Developer ID Installer:"), result.output.contains("(" + team + ")") else { throw AppUpdateInstallError.invalidSignature }
    }

    private func extractDiskImage(_ archive: URL, in folder: URL, identifier: String, package: Bool = false) async throws -> URL {
        let mount = folder.appendingPathComponent("mount", isDirectory: true)
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", "-mountpoint", mount.path, archive.path], timeoutSeconds: 90))
        guard result.exitCode == 0, !result.timedOut, !result.cancelled,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              entities.contains(where: { $0["mount-point"] as? String == mount.path }) else {
            // Attachment can complete just as cancellation arrives; detach our mount even then.
            try? await detachOwnedImage(mount)
            throw AppUpdateInstallError.commandFailed("无法只读挂载磁盘镜像")
        }
        do {
            let app = try package ? Self.findPackage(in: mount) : Self.findApp(in: mount, identifier: identifier)
            if package { try UpdatePaths.noLinks(app) } else { try Self.validateApplicationTree(app) }
            let destination = folder.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let copied = destination.appendingPathComponent(app.lastPathComponent)
            try await command("/usr/bin/ditto", ["--rsrc", "--extattr", app.path, copied.path], timeout: 180)
            try await detachOwnedImage(mount)
            return copied
        } catch {
            try? await detachOwnedImage(mount)
            throw error
        }
    }

    private func detachOwnedImage(_ mount: URL) async throws {
        // A cancelled parent task must still release the read-only image it owns.
        let result = await Task.detached {
            await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/hdiutil", arguments: ["detach", mount.path], timeoutSeconds: 30))
        }.value
        guard result.exitCode == 0, !result.timedOut else { throw AppUpdateInstallError.commandFailed("磁盘镜像仍被占用，请弹出 Orbit 临时镜像后重试。") }
    }

    private static func findPackage(in root: URL) throws -> URL {
        var packages: [URL] = []; var count = 0
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw AppUpdateInstallError.unsafeArchive }
        for case let url as URL in iterator {
            try Task.checkCancellation(); count += 1
            guard count <= 150_000 else { throw AppUpdateInstallError.archiveTooLarge }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if ["pkg", "mpkg"].contains(url.pathExtension.lowercased()) { packages.append(url); iterator.skipDescendants() }
            else if url.pathExtension.lowercased() == "app" || url.pathComponents.count - root.pathComponents.count > 4 { iterator.skipDescendants() }
        }
        guard packages.count == 1 else { throw AppUpdateInstallError.unsupported }
        return packages[0]
    }

    private static func findApp(in root: URL, identifier: String) throws -> URL {
        var matches: [URL] = []; var visited = 0
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw AppUpdateInstallError.unsafeArchive }
        for case let url as URL in iterator {
            try Task.checkCancellation(); visited += 1
            guard visited <= 150_000 else { throw AppUpdateInstallError.archiveTooLarge }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "app", values.isDirectory == true {
                iterator.skipDescendants()
                if try info(url)["CFBundleIdentifier"] as? String == identifier { matches.append(url) }
            }
            if url.pathComponents.count - root.pathComponents.count > 4 { iterator.skipDescendants() }
        }
        guard matches.count == 1 else { throw AppUpdateInstallError.identityMismatch }
        return matches[0]
    }

    static func validateApplicationTree(_ app: URL) throws {
        try UpdatePaths.noLinks(app)
        guard let iterator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else { throw AppUpdateInstallError.unsafeArchive }
        var count = 0; var total: Int64 = 0
        for case let url as URL in iterator {
            try Task.checkCancellation(); count += 1
            guard count <= 150_000 else { throw AppUpdateInstallError.archiveTooLarge }
            var item = stat()
            guard lstat(url.path, &item) == 0, item.st_mode & 0o6000 == 0 else { throw AppUpdateInstallError.unsafeArchive }
            let type = item.st_mode & S_IFMT
            if type == S_IFLNK {
                iterator.skipDescendants()
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                guard !link.hasPrefix("/"), let resolved = UpdatePaths.lexical(url.deletingLastPathComponent().path + "/" + link),
                      resolved.hasPrefix(app.path + "/") else { throw AppUpdateInstallError.unsafeArchive }
                let physical = url.resolvingSymlinksInPath().path
                // The lexical path check prevents dot-dot escape; realpath catches chains of internal symlinks.
                guard let rootPhysical = realpath(app.path, nil), let targetPhysical = realpath(url.path, nil) else { throw AppUpdateInstallError.unsafeArchive }
                defer { free(rootPhysical); free(targetPhysical) }
                let root = String(cString: rootPhysical), target = String(cString: targetPhysical)
                guard target.hasPrefix(root + "/"), !physical.isEmpty else { throw AppUpdateInstallError.unsafeArchive }
            } else if type == S_IFREG {
                guard item.st_nlink == 1 else { throw AppUpdateInstallError.unsafeArchive }
                total += max(0, item.st_size)
            } else if type != S_IFDIR { throw AppUpdateInstallError.unsafeArchive }
            guard total <= 8_589_934_592 else { throw AppUpdateInstallError.archiveTooLarge }
        }
    }

    /// libarchive only decompresses bytes. Paths, output creation and links are checked here, never delegated to archive filenames.
    static func extractArchive(_ source: URL, to destination: URL) throws {
        try UpdatePaths.noLinks(source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try UpdatePaths.noLinks(destination)
        guard let reader = archive_read_new() else { throw AppUpdateInstallError.unsafeArchive }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader); archive_read_support_format_zip(reader)
        guard archive_read_open_filename(reader, source.path, 65_536) == ARCHIVE_OK else { throw AppUpdateInstallError.unsafeArchive }
        var entry: OpaquePointer?; var count = 0; var total: Int64 = 0
        var links: [(URL, String)] = []
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry, let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry) else { throw AppUpdateInstallError.unsafeArchive }
            let name = String(cString: raw)
            let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !name.hasPrefix("/"), !name.contains("\\"), !components.isEmpty,
                  !components.contains(".."), !components.contains("."), name.utf8.count < 3000,
                  !name.unicodeScalars.contains(where: { $0.value < 32 }) else { throw AppUpdateInstallError.unsafeArchive }
            if components[0] == "__MACOSX" { archive_read_data_skip(reader); continue }
            let key = components.joined(separator: "/")
            guard seen.insert(key).inserted else { throw AppUpdateInstallError.unsafeArchive }
            count += 1; guard count <= 150_000 else { throw AppUpdateInstallError.archiveTooLarge }
            let output = destination.appendingPathComponent(key)
            try UpdatePaths.createParents(output.deletingLastPathComponent(), within: destination)
            guard archive_entry_hardlink(entry) == nil else { throw AppUpdateInstallError.unsafeArchive }
            let type = archive_entry_filetype(entry)
            let permissions = archive_entry_perm(entry)
            guard permissions & 0o6000 == 0 else { throw AppUpdateInstallError.unsafeArchive }
            if type == S_IFDIR {
                if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
                try UpdatePaths.noLinks(output)
            } else if type == S_IFLNK {
                guard let pointer = archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry) else { throw AppUpdateInstallError.unsafeArchive }
                let target = String(cString: pointer)
                guard !target.hasPrefix("/"), !target.contains("\\"), let resolved = UpdatePaths.lexical(output.deletingLastPathComponent().path + "/" + target),
                      resolved.hasPrefix(destination.path + "/") else { throw AppUpdateInstallError.unsafeArchive }
                links.append((output, target)); archive_read_data_skip(reader)
            } else if type == S_IFREG {
                let size = archive_entry_size(entry)
                guard size >= 0, size <= 2_147_483_648, total <= 8_589_934_592 - size else { throw AppUpdateInstallError.archiveTooLarge }
                total += size
                let available = try destination.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
                guard Int64(available) >= size + 134_217_728 else { throw AppUpdateInstallError.archiveTooLarge }
                let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw AppUpdateInstallError.unsafeArchive }
                do {
                    var buffer = [UInt8](repeating: 0, count: 65_536); var written: Int64 = 0
                    while true {
                        try Task.checkCancellation()
                        let amount = archive_read_data(reader, &buffer, buffer.count)
                        if amount == 0 { break }
                        guard amount > 0, written + Int64(amount) <= size else { throw AppUpdateInstallError.unsafeArchive }
                        var offset = 0
                        while offset < amount {
                            let result = buffer.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), amount - offset) }
                            guard result > 0 else { throw AppUpdateInstallError.commandFailed("写入安装文件失败") }
                            offset += result
                        }
                        written += Int64(amount)
                    }
                    guard written == size else { throw AppUpdateInstallError.unsafeArchive }
                    fchmod(descriptor, mode_t((permissions & 0o755) | 0o600)); close(descriptor)
                } catch { close(descriptor); throw error }
            } else { throw AppUpdateInstallError.unsafeArchive }
        }
        // No file is ever written through a link: symbolic links are created only after all regular entries.
        for (path, target) in links {
            try UpdatePaths.noLinks(path.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: path.path) else { throw AppUpdateInstallError.unsafeArchive }
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target)
        }
    }

    private static func swap(_ first: URL, _ second: URL) throws {
        try UpdatePaths.noLinks(first); try UpdatePaths.noLinks(second)
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == EACCES || errno == EPERM { throw AppUpdateInstallError.administratorRequired }
            throw AppUpdateInstallError.commandFailed(String(cString: strerror(errno)))
        }
        let directory = open(first.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory >= 0 { fsync(directory); close(directory) }
    }
}

struct UpdateAppIdentity: Codable, Sendable {
    let identifier: String
    let team: String
    let build: String
    let codeHash: String
    let requirement: String
    let device: UInt64
    let inode: UInt64
    let developerID: Bool

    static func read(_ url: URL, matching requirementText: String? = nil) throws -> UpdateAppIdentity {
        try UpdatePaths.noLinks(url)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw AppUpdateInstallError.invalidSignature }
        var requirement: SecRequirement?
        if let requirementText {
            guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else { throw AppUpdateInstallError.invalidSignature }
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw AppUpdateInstallError.invalidSignature }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let unique = info[kSecCodeInfoUnique as String] as? Data else { throw AppUpdateInstallError.invalidSignature }
        // A custom designated requirement can be permissive. Independently anchor the publisher to Apple and its Team.
        guard ApplicationPaths.validBundleID(identifier), team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw AppUpdateInstallError.invalidSignature }
        var publisher: SecRequirement?
        let publisherText = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(publisherText as CFString, [], &publisher) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, publisher) == errSecSuccess else { throw AppUpdateInstallError.invalidSignature }
        var designated: SecRequirement?; var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess, let designated,
              SecRequirementCopyString(designated, [], &text) == errSecSuccess, let text else { throw AppUpdateInstallError.invalidSignature }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        try UpdatePaths.noLinks(plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == identifier, let build = plist["CFBundleVersion"] as? String,
              plist["CFBundlePackageType"] as? String == "APPL" else { throw AppUpdateInstallError.identityMismatch }
        var statbuf = stat(); guard lstat(url.path, &statbuf) == 0 else { throw AppUpdateInstallError.invalidTarget }
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let developerID = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }?.hasPrefix("Developer ID Application:") ?? false
        return UpdateAppIdentity(identifier: identifier, team: team, build: build, codeHash: unique.base64EncodedString(),
                                 requirement: text as String, device: UInt64(statbuf.st_dev), inode: UInt64(statbuf.st_ino), developerID: developerID)
    }
}

enum UpdatePaths {
    static func noLinks(_ url: URL) throws {
        guard url.isFileURL, url.pathComponents.allSatisfy({ $0 != ".." && $0 != "." }) else { throw AppUpdateInstallError.unsafeArchive }
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0, metadata.st_mode & S_IFMT != S_IFLNK else { throw AppUpdateInstallError.unsafeArchive }
        }
    }
    static func lexical(_ path: String) -> String? {
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
            else { components.append(part) }
        }
        return "/" + components.joined(separator: "/")
    }
    static func createParents(_ folder: URL, within root: URL) throws {
        guard folder.path == root.path || folder.path.hasPrefix(root.path + "/") else { throw AppUpdateInstallError.unsafeArchive }
        var current = root
        for part in folder.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(part)
            if !FileManager.default.fileExists(atPath: current.path) { try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
            try noLinks(current)
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw AppUpdateInstallError.unsafeArchive }
        }
    }
}

private final class UpdateDownloadRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? AppUpdateChecker.validateFeedURL(url, resolveHost: true)) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
