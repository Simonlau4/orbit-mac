import Foundation
import Darwin

struct UpdateRootJournal: Codable {
    let id: UUID
    let clientUID: uid_t
    let targetLeaf: String
    let original: UpdateAppIdentity
    var replacement: UpdateAppIdentity?
    let expectedReplacementHash: String
    var state: AppUpdateInstallationState
    var message: String
}

/// Only system() is reachable from the signed root agent. Fixture configuration is rejected in root processes.
final class UpdateAuthorizationEngine {
    struct Configuration {
        let applications: URL
        let transactions: URL
        let receipts: URL
        let requests: URL
        let owner: uid_t
        let clientUID: uid_t
        let fixture: Bool
        var validateClient: () throws -> Void
        let running: (URL, String) throws -> Bool
        var afterSwap: (() throws -> Void)? = nil
        var authenticatedRequest: Data? = nil
        var beforeSwap: (() throws -> Void)? = nil
    }
    let configuration: Configuration
    private var verificationDirectory: (descriptor: Int32, url: URL)?
    init(configuration: Configuration) throws {
        guard configuration.fixture ? geteuid() != 0 : (geteuid() == 0 && configuration.owner == 0 && configuration.applications.path == "/Applications" && configuration.transactions == UpdateAuthorizationPaths.transactions && configuration.receipts == UpdateAuthorizationPaths.receipts) else { throw UpdateAuthorizationError.administratorRequired }
        guard configuration.fixture || (configuration.afterSwap == nil && configuration.beforeSwap == nil) else { throw UpdateAuthorizationError.invalidRequest }
        self.configuration = configuration
    }

    func run(_ invocation: UpdateAuthorizationInvocation) async throws -> UpdateAuthorizationReceipt {
        try configuration.validateClient()
        let apps = try UpdateFD.openDirectory(configuration.applications, owners: [0, configuration.owner], forbidWritable: false)
        defer { close(apps) }
        let parent = try UpdateFD.metadata(apps)
        guard parent.st_uid == configuration.owner, parent.st_mode & 0o002 == 0 else { throw UpdateAuthorizationError.unsafePermissions }
        try UpdateFD.noWriteACL(apps)
        let storage = try storageDirectory(configuration.transactions, privateLeaf: true)
        defer { close(storage) }
        let lock = openat(storage, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw UpdateFD.failure() }; defer { close(lock) }
        let lockInfo = try UpdateFD.metadata(lock)
        guard lockInfo.st_uid == configuration.owner, lockInfo.st_nlink == 1, lockInfo.st_mode & 0o7777 == 0o600,
              lockInfo.st_mode & S_IFMT == S_IFREG, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw UpdateAuthorizationError.busy }
        defer { flock(lock, LOCK_UN) }
        let inboxRoot = try UpdateFD.openDirectory(configuration.requests, owners: [0, configuration.clientUID], forbidWritable: true)
        defer { close(inboxRoot) }
        let key = invocation.transactionID.uuidString.lowercased()
        let inbox = try UpdateFD.childDirectory(inboxRoot, name: key, owner: configuration.clientUID, mode: 0o700)
        defer { close(inbox) }
        let bytes = try UpdateFD.readFile(inbox, name: "request.json", owner: configuration.clientUID, mode: 0o600, maximum: 8_192)
        guard (configuration.fixture || configuration.authenticatedRequest == bytes), UpdateAuthorizationPaths.digest(bytes) == invocation.requestDigest else { throw UpdateAuthorizationError.invalidRequest }
        let request = try JSONDecoder().decode(UpdateAuthorizationRequest.self, from: bytes)
        try request.validate(id: invocation.transactionID, operation: invocation.operation)
        let transaction = try UpdateFD.childDirectory(storage, name: key, owner: configuration.owner, mode: 0o700, create: invocation.operation == .install)
        defer { close(transaction) }
        let root = configuration.transactions.appendingPathComponent(key)
        verificationDirectory = (transaction, root)
        defer { verificationDirectory = nil }
        var journal: UpdateRootJournal
        if UpdateFD.exists(transaction, "journal.json") {
            journal = try JSONDecoder().decode(UpdateRootJournal.self, from: UpdateFD.readFile(transaction, name: "journal.json", owner: configuration.owner, mode: 0o600, maximum: 32_768))
            guard journal.id == request.id, journal.clientUID == configuration.clientUID, journal.targetLeaf == request.targetLeaf,
                  !journal.original.identifier.hasPrefix("com.apple."), journal.original.identifier != "com.orbitmac.Orbit", !journal.original.identifier.hasPrefix("com.orbitmac.Orbit.") else { throw UpdateAuthorizationError.invalidRequest }
            try reconcile(&journal, apps: apps, transaction: transaction, root: root)
        } else {
            guard invocation.operation == .install else { throw UpdateAuthorizationError.invalidState }
            let original = try inspectProtectedApp(parentFD: apps, leaf: request.targetLeaf)
            guard original.codeHash == request.originalHash else { throw UpdateAuthorizationError.sourceChanged }
            journal = UpdateRootJournal(id: request.id, clientUID: configuration.clientUID, targetLeaf: request.targetLeaf,
                                        original: original, expectedReplacementHash: request.replacementHash, state: .prepared, message: "管理员安装准备中，原应用尚未更改。")
            try persist(journal, at: transaction)
        }
        do {
            if invocation.operation == .install, journal.state == .prepared {
                guard request.originalHash == journal.original.codeHash, request.replacementHash == journal.expectedReplacementHash else { throw UpdateAuthorizationError.invalidRequest }
                if UpdateFD.exists(transaction, "replacement.app") { try UpdateFD.removeOwnTree(transaction, name: "replacement.app", owner: configuration.owner) }
                let source = try UpdateFD.childDirectory(inbox, name: "payload.app", owner: configuration.clientUID)
                defer { close(source) }
                guard mkdirat(transaction, "replacement.app", 0o755) == 0 else { throw UpdateFD.failure() }
                let destination = try UpdateFD.childDirectory(transaction, name: "replacement.app", owner: configuration.owner)
                defer { close(destination) }
                var budget = UpdateFD.CopyBudget()
                try UpdateFD.inspectOrCopy(source, destination: destination, owner: configuration.clientUID, rootOwned: false, budget: &budget)
                guard fchmod(destination, 0o755) == 0 else { throw UpdateFD.failure() }
                let candidate = root.appendingPathComponent("replacement.app")
                try AppUpdateInstaller.validateApplicationTree(candidate)
                let replacement = try UpdateAppIdentity.read(candidate, matching: journal.original.requirement)
                guard replacement.identifier == journal.original.identifier, replacement.team == journal.original.team,
                      replacement.codeHash == request.replacementHash, replacement.build.compare(journal.original.build, options: .numeric) == .orderedDescending else { throw AppUpdateInstallError.identityMismatch }
                try UpdateAuthorizationCompatibility.validate(candidate)
                if journal.original.developerID {
                    let assessment = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", candidate.path], timeoutSeconds: 90))
                    guard assessment.exitCode == 0, !assessment.cancelled, !assessment.timedOut else { throw AppUpdateInstallError.invalidSignature }
                }
                journal.replacement = replacement
                try configuration.validateClient()
                try assertTarget(journal.original, apps: apps, leaf: journal.targetLeaf)
                guard !(try configuration.running(configuration.applications.appendingPathComponent(journal.targetLeaf), journal.original.identifier)) else { throw UpdateAuthorizationError.runningApplication }
                guard parent.st_dev == (try UpdateFD.metadata(destination)).st_dev else { throw UpdateAuthorizationError.unsupportedTarget }
                journal.state = .installing; journal.message = "正在原子替换，旧版本将保留。"; try persist(journal, at: transaction)
                try configuration.beforeSwap?()
                try UpdateFD.swap(apps, journal.targetLeaf, transaction, "replacement.app")
                guard matches(try UpdateFD.entry(transaction, "replacement.app"), identity: journal.original) else {
                    withdrawUnmatchedCapture(current: replacement, apps: apps, leaf: journal.targetLeaf, transaction: transaction, slot: "replacement.app")
                    journal.state = .failed; journal.message = "交换时目标条目发生变化；已停止更新，额外副本保留在管理员恢复目录。"
                    try persist(journal, at: transaction)
                    throw UpdateAuthorizationError.sourceChanged
                }
                // After the atomic exchange the real old bundle is inside our private root directory.
                guard renameat(transaction, "replacement.app", transaction, "backup.app") == 0 else { throw UpdateFD.failure() }
                fsync(transaction)
                do {
                    try configuration.afterSwap?()
                    try assertTarget(replacement, apps: apps, leaf: journal.targetLeaf)
                    try verify(root.appendingPathComponent("backup.app"), expected: journal.original)
                    journal.state = .installed; journal.message = "管理员更新已安装，旧版本可恢复。"
                } catch {
                    try assertTarget(replacement, apps: apps, leaf: journal.targetLeaf)
                    try verify(root.appendingPathComponent("backup.app"), expected: journal.original)
                    try UpdateFD.swap(apps, journal.targetLeaf, transaction, "backup.app")
                    guard matches(try UpdateFD.entry(transaction, "backup.app"), identity: replacement) else {
                        withdrawUnmatchedCapture(current: journal.original, apps: apps, leaf: journal.targetLeaf, transaction: transaction, slot: "backup.app")
                        journal.state = .failed; try persist(journal, at: transaction)
                        throw UpdateAuthorizationError.sourceChanged
                    }
                    try assertTarget(journal.original, apps: apps, leaf: journal.targetLeaf)
                    journal.state = .restored; journal.message = "安装后核验失败，已恢复原版本。"
                }
                try persist(journal, at: transaction)
            } else if invocation.operation == .restore, journal.state == .installed {
                guard let replacement = journal.replacement else { throw UpdateAuthorizationError.invalidState }
                let target = configuration.applications.appendingPathComponent(journal.targetLeaf)
                try assertTarget(replacement, apps: apps, leaf: journal.targetLeaf)
                try verify(root.appendingPathComponent("backup.app"), expected: journal.original)
                guard !(try configuration.running(target, journal.original.identifier)) else { throw UpdateAuthorizationError.runningApplication }
                try configuration.validateClient()
                journal.state = .restoring; journal.message = "正在恢复原版本。"; try persist(journal, at: transaction)
                try configuration.beforeSwap?()
                try UpdateFD.swap(apps, journal.targetLeaf, transaction, "backup.app")
                guard matches(try UpdateFD.entry(transaction, "backup.app"), identity: replacement) else {
                    withdrawUnmatchedCapture(current: journal.original, apps: apps, leaf: journal.targetLeaf, transaction: transaction, slot: "backup.app")
                    journal.state = .failed; journal.message = "恢复时目标条目发生变化；已停止，额外副本保留在管理员恢复目录。"
                    try persist(journal, at: transaction)
                    throw UpdateAuthorizationError.sourceChanged
                }
                try assertTarget(journal.original, apps: apps, leaf: journal.targetLeaf)
                journal.state = .restored; journal.message = "原版本已恢复，替换下来的版本仍保留。"; try persist(journal, at: transaction)
            } else if journal.state == .installed, let replacement = journal.replacement {
                try assertTarget(replacement, apps: apps, leaf: journal.targetLeaf)
                try verify(root.appendingPathComponent("backup.app"), expected: journal.original)
            } else if journal.state == .restored, let replacement = journal.replacement {
                try assertTarget(journal.original, apps: apps, leaf: journal.targetLeaf)
                try verify(root.appendingPathComponent("backup.app"), expected: replacement)
            } else { throw UpdateAuthorizationError.invalidState }
            return try publish(journal, digest: invocation.requestDigest)
        } catch {
            do {
                try reconcile(&journal, apps: apps, transaction: transaction, root: root)
                if journal.state == .installed, let replacement = journal.replacement {
                    try assertTarget(replacement, apps: apps, leaf: journal.targetLeaf)
                    try verify(root.appendingPathComponent("backup.app"), expected: journal.original)
                } else if journal.state == .restored, let replacement = journal.replacement {
                    try assertTarget(journal.original, apps: apps, leaf: journal.targetLeaf)
                    try verify(root.appendingPathComponent("backup.app"), expected: replacement)
                } else if journal.state == .prepared { try assertTarget(journal.original, apps: apps, leaf: journal.targetLeaf) }
            } catch { journal.state = .failed }
            journal.message = error.localizedDescription
            if [.installing, .restoring].contains(journal.state) { journal.state = .failed }
            try? persist(journal, at: transaction); _ = try? publish(journal, digest: invocation.requestDigest)
            throw error
        }
    }

    private func matches(_ info: stat, identity: UpdateAppIdentity) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == configuration.owner
            && UInt64(info.st_dev) == identity.device && UInt64(info.st_ino) == identity.inode
    }

    /// Snapshot verification never resolves the user-replaceable Applications/leaf pathname.
    private func snapshotIdentity(_ source: Int32) throws -> UpdateAppIdentity {
        guard let verificationDirectory else { throw UpdateAuthorizationError.invalidState }
        let before = try UpdateFD.metadata(source)
        let name = "verification-" + UUID().uuidString + ".app"
        let destination = try UpdateFD.childDirectory(verificationDirectory.descriptor, name: name, owner: configuration.owner, mode: 0o755, create: true)
        defer { close(destination); try? UpdateFD.removeOwnTree(verificationDirectory.descriptor, name: name, owner: configuration.owner) }
        var budget = UpdateFD.CopyBudget()
        try UpdateFD.inspectOrCopy(source, destination: destination, owner: configuration.owner, rootOwned: true, budget: &budget)
        let path = verificationDirectory.url.appendingPathComponent(name)
        try AppUpdateInstaller.validateApplicationTree(path)
        let proof = try UpdateAppIdentity.read(path)
        guard UpdateFD.same(before, try UpdateFD.metadata(source)) else { throw UpdateAuthorizationError.sourceChanged }
        return UpdateAppIdentity(identifier: proof.identifier, team: proof.team, build: proof.build, codeHash: proof.codeHash,
            requirement: proof.requirement, device: UInt64(before.st_dev), inode: UInt64(before.st_ino), developerID: proof.developerID)
    }

    private func inspectProtectedApp(parentFD: Int32, leaf: String) throws -> UpdateAppIdentity {
        guard UpdateAuthorizationRequest.validLeaf(leaf) else { throw UpdateAuthorizationError.unsupportedTarget }
        let fd = try UpdateFD.childDirectory(parentFD, name: leaf, owner: configuration.owner)
        defer { close(fd) }
        let flags = try UpdateFD.metadata(fd).st_flags
        guard flags & 0x000e0006 == 0 else { throw UpdateAuthorizationError.unsupportedTarget } // immutable, append-only or SIP-restricted
        let identity = try snapshotIdentity(fd)
        guard !identity.identifier.hasPrefix("com.apple."), identity.identifier != "com.orbitmac.Orbit", !identity.identifier.hasPrefix("com.orbitmac.Orbit."),
              matches(try UpdateFD.entry(parentFD, leaf), identity: identity) else { throw UpdateAuthorizationError.unsupportedTarget }
        return identity
    }

    private func assertTarget(_ identity: UpdateAppIdentity, apps: Int32, leaf: String) throws {
        guard matches(try UpdateFD.entry(apps, leaf), identity: identity) else { throw UpdateAuthorizationError.sourceChanged }
        let fd = try UpdateFD.childDirectory(apps, name: leaf, owner: configuration.owner)
        defer { close(fd) }
        guard matches(try UpdateFD.metadata(fd), identity: identity) else { throw UpdateAuthorizationError.sourceChanged }
        let actual = try snapshotIdentity(fd)
        guard actual.codeHash == identity.codeHash, actual.identifier == identity.identifier, actual.team == identity.team,
              actual.build == identity.build, matches(try UpdateFD.entry(apps, leaf), identity: identity) else { throw UpdateAuthorizationError.sourceChanged }
    }

    /// Private backups are inspected only after proving this is the captured, expected immutable bundle.
    private func verify(_ app: URL, expected: UpdateAppIdentity) throws {
        var info = stat()
        guard lstat(app.path, &info) == 0, matches(info, identity: expected) else { throw UpdateAuthorizationError.sourceChanged }
        let actual = try UpdateAppIdentity.read(app, matching: expected.requirement)
        guard actual.codeHash == expected.codeHash, actual.identifier == expected.identifier, actual.team == expected.team,
              actual.build == expected.build, actual.device == expected.device, actual.inode == expected.inode else { throw UpdateAuthorizationError.sourceChanged }
    }

    /// Only rename directory entries. An unexpected captured item is never opened, chmodded, chowned or deleted.
    private func withdrawUnmatchedCapture(current: UpdateAppIdentity, apps: Int32, leaf: String, transaction: Int32, slot: String) {
        if let entry = try? UpdateFD.entry(apps, leaf), matches(entry, identity: current) {
            try? UpdateFD.swap(apps, leaf, transaction, slot)
        }
    }

    private func reconcile(_ journal: inout UpdateRootJournal, apps: Int32, transaction: Int32, root: URL) throws {
        guard [.installing, .restoring].contains(journal.state), let replacement = journal.replacement else { return }
        let targetEntry = try UpdateFD.entry(apps, journal.targetLeaf)
        let backupName = UpdateFD.exists(transaction, "backup.app") ? "backup.app" : "replacement.app"
        let backup = root.appendingPathComponent(backupName)
        if matches(targetEntry, identity: replacement) {
            try assertTarget(replacement, apps: apps, leaf: journal.targetLeaf)
            try verify(backup, expected: journal.original)
            if backupName == "replacement.app" { guard renameat(transaction, backupName, transaction, "backup.app") == 0 else { throw UpdateFD.failure() } }
            journal.state = .installed; journal.message = "已核对中断的安装，原版本可恢复。"
        } else if matches(targetEntry, identity: journal.original) {
            try assertTarget(journal.original, apps: apps, leaf: journal.targetLeaf)
            try verify(backup, expected: replacement)
            journal.state = journal.state == .restoring || backupName == "backup.app" ? .restored : .prepared
            journal.message = "已核对中断状态，原版本完整。"
        } else { throw UpdateAuthorizationError.sourceChanged }
        try persist(journal, at: transaction)
    }
    private func persist(_ journal: UpdateRootJournal, at fd: Int32) throws {
        try UpdateFD.writeFile(fd, name: "journal.json", data: JSONEncoder().encode(journal), mode: 0o600)
    }
    private func publish(_ journal: UpdateRootJournal, digest: String) throws -> UpdateAuthorizationReceipt {
        let root = try storageDirectory(configuration.receipts, privateLeaf: false); defer { close(root) }
        let user = try UpdateFD.childDirectory(root, name: String(configuration.clientUID), owner: configuration.owner, mode: 0o755, create: true)
        defer { close(user) }
        let receipt = UpdateAuthorizationReceipt(transactionID: journal.id, clientUID: journal.clientUID, targetLeaf: journal.targetLeaf,
            identifier: journal.original.identifier, originalHash: journal.original.codeHash,
            replacementHash: journal.replacement?.codeHash ?? journal.expectedReplacementHash,
            originalBuild: journal.original.build, replacementBuild: journal.replacement?.build ?? "",
            state: journal.state, message: journal.message, completedAt: Date(), requestDigest: digest)
        try UpdateFD.writeFile(user, name: journal.id.uuidString.lowercased() + ".json", data: JSONEncoder().encode(receipt), mode: 0o644)
        return receipt
    }
    private func storageDirectory(_ path: URL, privateLeaf: Bool) throws -> Int32 {
        if configuration.fixture {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: privateLeaf ? 0o700 : 0o755])
            return try UpdateFD.openDirectory(path, owners: [0, configuration.owner], forbidWritable: true)
        }
        let support = try UpdateFD.openDirectory(URL(fileURLWithPath: "/Library/Application Support"), owners: [0], forbidWritable: true)
        defer { close(support) }
        let orbit = try UpdateFD.childDirectory(support, name: "Orbit", owner: 0, mode: 0o755, create: true)
        defer { close(orbit) }
        return try UpdateFD.childDirectory(orbit, name: path.lastPathComponent, owner: 0, mode: privateLeaf ? 0o700 : 0o755, create: true)
    }
}

enum UpdateAuthorizationCompatibility {
    static func validate(_ app: URL) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else { throw AppUpdateInstallError.incompatible }
        #if arch(arm64)
        let name = "arm64"; let cpu: UInt32 = 0x0100000c
        #else
        let name = "x86_64"; let cpu: UInt32 = 0x01000007
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let perArch = info["LSMinimumSystemVersionByArchitecture"] as? [String: String]
        for minimum in [info["LSMinimumSystemVersion"] as? String, perArch?[name]].compactMap({ $0 }) {
            guard current.compare(minimum, options: .numeric) != .orderedAscending else { throw AppUpdateInstallError.incompatible }
        }
        let executableURL = app.appendingPathComponent("Contents/MacOS/" + executable)
        try UpdatePaths.noLinks(executableURL)
        let handle = try FileHandle(forReadingFrom: executableURL); defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 4096) ?? Data())
        func word(_ offset: Int, big: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let values = Array(bytes[offset..<offset + 4]); let v = big ? values : Array(values.reversed())
            return v.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = word(0, big: true) else { throw AppUpdateInstallError.incompatible }
        if [0xcffaedfe, 0xcefaedfe, 0xfeedfacf, 0xfeedface].contains(magic) {
            guard word(4, big: magic == 0xfeedfacf || magic == 0xfeedface) == cpu else { throw AppUpdateInstallError.incompatible }
        } else {
            guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { throw AppUpdateInstallError.incompatible }
            let big = magic == 0xcafebabe || magic == 0xcafebabf
            guard let count = word(4, big: big), count > 0, count <= 32 else { throw AppUpdateInstallError.incompatible }
            let width = [0xcafebabf, 0xbfbafeca].contains(magic) ? 32 : 20
            guard (0..<Int(count)).contains(where: { word(8 + $0 * width, big: big) == cpu }) else { throw AppUpdateInstallError.incompatible }
        }
    }
}
