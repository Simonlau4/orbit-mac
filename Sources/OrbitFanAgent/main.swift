import Foundation
import Security
import Darwin
import OrbitCore

// A one-session hardware process. No shell, package, arbitrary file or arbitrary SMC API.
nonisolated(unsafe) private var stopping: sig_atomic_t = 0
signal(SIGTERM) { _ in stopping = 1 }
signal(SIGINT) { _ in stopping = 1 }
signal(SIGHUP) { _ in stopping = 1 }

enum AgentError: Error { case invalidRequest, invalidClient, busy }
let installedPath = "/Library/PrivilegedHelperTools/com.orbitmac.Orbit.FanAgent"

struct ClientIdentity: Equatable {
    let uid: uid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
}

func processIdentity(_ pid: pid_t) throws -> ClientIdentity {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
          info.pbi_uid > 0, info.pbi_uid == info.pbi_ruid else { throw AgentError.invalidClient }
    return ClientIdentity(uid: info.pbi_uid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
}

func staticCode(_ code: SecCode) throws -> SecStaticCode {
    var result: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &result) == errSecSuccess, let result else { throw AgentError.invalidClient }
    return result
}

func clientCode(_ pid: pid_t, expectedTeam: String, identity: ClientIdentity) throws {
    guard try processIdentity(pid) == identity else { throw AgentError.invalidClient }
    var guest: SecCode?
    let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest) == errSecSuccess, let code = guest else { throw AgentError.invalidClient }
    var requirement: SecRequirement?
    let text = "anchor apple generic and identifier \"com.orbitmac.Orbit\" and certificate leaf[subject.OU] = \"\(expectedTeam)\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw AgentError.invalidClient }
    let diskCode = try staticCode(code)
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(diskCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { throw AgentError.invalidClient }
    let values = info as? [String: Any] ?? [:]
    let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    // CSCommon.h kSecCodeSignatureRuntime is unavailable as a Swift global.
    guard flags & 0x10000 != 0,
          (entitlements["com.apple.security.get-task-allow"] as? Bool) != true,
          (entitlements["com.apple.security.cs.disable-library-validation"] as? Bool) != true,
          (entitlements["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool) != true else { throw AgentError.invalidClient }
}

func signingTeam() throws -> String {
    var ownCode: SecCode?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { throw AgentError.invalidClient }
    let diskCode = try staticCode(ownCode)
    guard SecStaticCodeCheckValidity(diskCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw AgentError.invalidClient }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(diskCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any],
          let url = values[kSecCodeInfoMainExecutable as String] as? URL, url.path == installedPath,
          values[kSecCodeInfoIdentifier as String] as? String == "com.orbitmac.Orbit.FanAgent",
          let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
          team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw AgentError.invalidClient }
    var cursor = URL(fileURLWithPath: installedPath)
    var isFile = true
    while true {
        var st = stat()
        guard lstat(cursor.path, &st) == 0, st.st_uid == 0, st.st_gid == 0,
              st.st_mode & 0o777 == 0o755,
              st.st_mode & S_IFMT == (isFile ? S_IFREG : S_IFDIR),
              st.st_mode & 0o6000 == 0,
              !isFile || (st.st_nlink == 1 && st.st_mode & 0o1000 == 0) else { throw AgentError.invalidClient }
        if cursor.path == "/" { break }
        cursor.deleteLastPathComponent(); isFile = false
    }
    var requirement: SecRequirement?
    let text = "anchor apple generic and identifier \"com.orbitmac.Orbit.FanAgent\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          SecCodeCheckValidity(ownCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw AgentError.invalidClient }
    return team
}

// Pin the opened directory, so ancestor renames or symlink swaps cannot change the request root.
func openLeaseDirectory(home: URL, owner: uid_t) throws -> Int32 {
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw AgentError.invalidRequest }
    let directory = home.appendingPathComponent("Library/Application Support/Orbit/FanControl")
    do {
        for component in directory.pathComponents where component != "/" {
            guard component != ".", component != ".." else { throw AgentError.invalidRequest }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw AgentError.invalidRequest }
            close(fd); fd = next
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  st.st_uid == owner || st.st_uid == 0, st.st_mode & 0o022 == 0 else { throw AgentError.invalidRequest }
        }
        return fd
    } catch { close(fd); throw error }
}

func readLease(directoryFD: Int32, name: String, expectedID: UUID, expectedOwner: uid_t) throws -> FanControlLease {
    guard !name.contains("/"), name.lowercased() == "\(expectedID.uuidString.lowercased()).json" else { throw AgentError.invalidRequest }
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw AgentError.invalidRequest }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == expectedOwner,
          before.st_nlink == 1, before.st_size > 0, before.st_size <= 2048,
          before.st_mode & 0o7777 == 0o600 else { throw AgentError.invalidRequest }
    var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
    guard read(fd, &bytes, bytes.count) == bytes.count else { throw AgentError.invalidRequest }
    var after = stat()
    guard fstat(fd, &after) == 0, after.st_size == before.st_size,
          after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
          after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw AgentError.invalidRequest }
    let lease = try JSONDecoder().decode(FanControlLease.self, from: Data(bytes))
    guard lease.id == expectedID, lease.valid() else { throw AgentError.invalidRequest }
    return lease
}

func run() async throws {
    guard geteuid() == 0, CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--client",
          let pid = Int32(CommandLine.arguments[2]), pid > 1, CommandLine.arguments[3] == "--lease" else { throw AgentError.invalidRequest }
    let team = try signingTeam()
    let identity = try processIdentity(pid)
    try clientCode(pid, expectedTeam: team, identity: identity)
    guard let account = getpwuid(identity.uid) else { throw AgentError.invalidClient }
    let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
    let directory = home.appendingPathComponent("Library/Application Support/Orbit/FanControl")
    let leaseURL = URL(fileURLWithPath: CommandLine.arguments[4])
    guard leaseURL.deletingLastPathComponent().path == directory.path, leaseURL.pathExtension == "json",
          let expectedID = UUID(uuidString: leaseURL.deletingPathExtension().lastPathComponent) else { throw AgentError.invalidRequest }
    let directoryFD = try openLeaseDirectory(home: home, owner: identity.uid)
    defer { close(directoryFD) }
    let lockFD = open("/private/var/run/com.orbitmac.Orbit.fans.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { throw AgentError.busy }
    defer { close(lockFD) }
    guard FanLockOwnership.normalizeRootLock(lockFD),
          flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw AgentError.busy }
    defer { flock(lockFD, LOCK_UN) }

    let first = try readLease(directoryFD: directoryFD, name: leaseURL.lastPathComponent, expectedID: expectedID, expectedOwner: identity.uid)
    let hardware = ThermalFanHardware()
    let sleepGuard = try ThermalSleepGuard(hardware: hardware)
    defer { sleepGuard.close() }
    let reader = ThermalReader()
    let monitor = SystemMonitor()
    var policy = FanCoolingPolicy(mode: first.mode, now: ProcessInfo.processInfo.systemUptime)
    var mode = first.mode
    var reason = "已恢复系统自动调节。"
    var controlled = false
    var explicitAutomaticRequested = first.mode == .automatic
    var operationError: Error?
    do {
        while stopping == 0 && !sleepGuard.shouldStop {
            try clientCode(pid, expectedTeam: team, identity: identity)
            let lease = try readLease(directoryFD: directoryFD, name: leaseURL.lastPathComponent, expectedID: expectedID, expectedOwner: identity.uid)
            if lease.mode == .automatic { explicitAutomaticRequested = true; break }
            if lease.mode != mode {
                mode = lease.mode
                policy = FanCoolingPolicy(mode: mode, now: policy.startedAt)
            }
            let snapshot = reader.sample()
            let cpu = await monitor.sample(includeProcesses: false).cpuUsage
            let decision = policy.update(snapshot: snapshot, cpuUsage: cpu, now: ProcessInfo.processInfo.systemUptime)
            if decision.shouldRestore { reason = decision.reason ?? reason; break }
            _ = try sleepGuard.apply(mode: decision.mode, targetFraction: decision.targetFraction)
            controlled = true
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if sleepGuard.shouldStop { reason = "系统睡眠已结束降温，已恢复自动调节。" }
    } catch { operationError = error; reason = "降温已结束：连接中断或请求过期。" }

    guard explicitAutomaticRequested || hardware.requiresAutomaticRestore else {
        // In particular, a foreign manual controller rejected before our first write
        // must remain untouched. Sleep callbacks use the same owned-only hardware guard.
        if let operationError { throw operationError }
        let automatic = reader.sample().automaticModeVerified == true
        let report = FanControlReport(mode: .automatic, message: "未启动风扇控制；现有设置保持不变。", restored: automatic)
        if let data = try? JSONEncoder().encode(report) { print(String(decoding: data, as: UTF8.self)) }
        return
    }
    var restored = false
    var restoreError: Error?
    for _ in 0..<5 {
        do {
            if explicitAutomaticRequested { _ = try hardware.apply(mode: .automatic, targetFraction: 0) }
            else { _ = try sleepGuard.restoreAutomatic() }
            restored = true; break
        }
        catch { restoreError = error; usleep(200_000) }
    }
    let report = FanControlReport(mode: .automatic,
        message: restored ? reason : "无法确认自动恢复，请重新运行恢复或重启 Mac。\(restoreError?.localizedDescription ?? "")", restored: restored)
    if let data = try? JSONEncoder().encode(report) { print(String(decoding: data, as: UTF8.self)) }
    if !restored { throw restoreError ?? AgentError.invalidRequest }
    if let operationError, !controlled { throw operationError }
}

do { try await run() }
catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
