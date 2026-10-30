import Foundation
import Security
import Darwin

public enum UpdateAuthorizationAgent {
    public static let installedPath = "/Library/PrivilegedHelperTools/com.orbitmac.Orbit.UpdateAgent"
    public static let signingIdentifier = "com.orbitmac.Orbit.UpdateAgent"

    /// The executable has no paths, commands, archive extraction or package-execution switches.
    public static func execute(arguments: [String]) async throws -> UpdateAuthorizationReceipt {
        guard geteuid() == 0 else { throw UpdateAuthorizationError.administratorRequired }
        guard arguments.count == 8, arguments[0] == "--client", let pid = Int32(arguments[1]), pid > 1,
              arguments[2] == "--operation", let operation = UpdateAuthorizationOperation(rawValue: arguments[3]),
              arguments[4] == "--transaction", let id = UUID(uuidString: arguments[5]), arguments[6] == "--request-digest" else { throw UpdateAuthorizationError.invalidRequest }
        let invocation = try UpdateAuthorizationInvocation(transactionID: id, operation: operation, clientPID: pid, requestDigest: arguments[7])
        let team = try signingTeam()
        let client = try UpdateAuthorizedClient(pid: pid, expectedTeam: team)
        try client.validate()
        let requestBytes = try UpdateAuthorizationChannel.authenticateClient(invocation, uid: client.uid)
        try client.validate()
        let configuration = UpdateAuthorizationEngine.Configuration(applications: URL(fileURLWithPath: "/Applications"),
            transactions: UpdateAuthorizationPaths.transactions, receipts: UpdateAuthorizationPaths.receipts,
            requests: UpdateAuthorizationPaths.requests(home: client.home), owner: 0, clientUID: client.uid,
            fixture: false, validateClient: { try client.validate() },
            running: UpdateAuthorizedClient.applicationHasProcesses, authenticatedRequest: requestBytes)
        return try await UpdateAuthorizationEngine(configuration: configuration).run(invocation)
    }

    private static func signingTeam() throws -> String {
        let binary = URL(fileURLWithPath: installedPath)
        let parent = try UpdateFD.openDirectory(binary.deletingLastPathComponent(), owners: [0], forbidWritable: true)
        defer { close(parent) }
        let info = try UpdateFD.entry(parent, binary.lastPathComponent)
        guard info.st_uid == 0, info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o755 else { throw UpdateAuthorizationError.invalidClient }
        let fd = openat(parent, binary.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UpdateAuthorizationError.invalidClient }; defer { close(fd) }
        try UpdateFD.noWriteACL(fd)
        var own: SecCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own else { throw UpdateAuthorizationError.invalidClient }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(own, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw UpdateAuthorizationError.invalidClient }
        let values = try UpdateAuthorizedClient.signingInformation(code)
        guard values[kSecCodeInfoMainExecutable as String] as? URL == binary,
              values[kSecCodeInfoIdentifier as String] as? String == signingIdentifier,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw UpdateAuthorizationError.invalidClient }
        try UpdateAuthorizedClient.validateRuntime(values)
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(signingIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(own, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw UpdateAuthorizationError.invalidClient }
        return team
    }
}

private struct UpdateAuthorizedClient {
    let pid: pid_t
    let uid: uid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let expectedTeam: String
    let home: URL

    init(pid: pid_t, expectedTeam: String) throws {
        let identity = try Self.process(pid)
        self.pid = pid; uid = identity.pbi_uid; startedSeconds = identity.pbi_start_tvsec
        startedMicroseconds = identity.pbi_start_tvusec; self.expectedTeam = expectedTeam
        guard let account = getpwuid(uid) else { throw UpdateAuthorizationError.invalidClient }
        home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))

    }
    static func process(_ pid: pid_t) throws -> proc_bsdinfo {
        var info = proc_bsdinfo(); let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size, info.pbi_uid > 0,
              info.pbi_uid == info.pbi_ruid else { throw UpdateAuthorizationError.invalidClient }
        return info
    }
    func validate() throws {
        let info = try Self.process(pid)
        guard info.pbi_uid == uid, info.pbi_start_tvsec == startedSeconds, info.pbi_start_tvusec == startedMicroseconds else { throw UpdateAuthorizationError.invalidClient }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &guest) == errSecSuccess, let guest else { throw UpdateAuthorizationError.invalidClient }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"com.orbitmac.Orbit\" and certificate leaf[subject.OU] = \"\(expectedTeam)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw UpdateAuthorizationError.invalidClient }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code else { throw UpdateAuthorizationError.invalidClient }
        try Self.validateRuntime(Self.signingInformation(code))
    }
    static func signingInformation(_ code: SecStaticCode) throws -> [String: Any] {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let result = information as? [String: Any] else { throw UpdateAuthorizationError.invalidClient }
        return result
    }
    static func validateRuntime(_ values: [String: Any]) throws {
        let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        guard flags & 0x10000 != 0,
              !["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables"].contains(where: { entitlements[$0] as? Bool == true }) else { throw UpdateAuthorizationError.invalidClient }
    }
    static func applicationHasProcesses(_ app: URL, identifier: String) throws -> Bool {
        let physical = "/System/Volumes/Data" + app.path
        let count = proc_listallpids(nil, 0)
        guard count > 0, count <= 200_000 else { throw UpdateAuthorizationError.runningApplication }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2 + 1024)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0, found <= pids.count else { throw UpdateAuthorizationError.runningApplication }
        for pid in pids.prefix(Int(found)) where pid > 1 {
            var bytes = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 {
                let path = String(cString: bytes)
                if path.hasPrefix(app.path + "/") || path.hasPrefix(physical + "/") { return true }
                // Translocated copies have another path. The kernel code identity still identifies the live App.
                var guest: SecCode?; var disk: SecStaticCode?
                if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &guest) == errSecSuccess,
                   let guest, SecCodeCopyStaticCode(guest, [], &disk) == errSecSuccess, let disk,
                   let values = try? signingInformation(disk), values[kSecCodeInfoIdentifier as String] as? String == identifier { return true }
            } else if errno == EPERM || errno == EACCES { throw UpdateAuthorizationError.runningApplication }
        }
        return false
    }
}
