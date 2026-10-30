import Foundation
import Darwin

/// A one-request capability bound by the kernel to the live signed GUI process.
/// The root agent connects to this user listener; no privileged listener or daemon exists.
final class UpdateAuthorizationChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var closed = false
    private let path: String
    private let inode: ino_t
    private let bytes: Data
    private let digest: String

    init(id: UUID, bytes: Data) throws {
        guard getuid() > 0, bytes.count <= 8_192 else { throw UpdateAuthorizationError.invalidRequest }
        self.bytes = bytes; digest = UpdateAuthorizationPaths.digest(bytes)
        path = Self.path(uid: getuid(), pid: getpid(), id: id)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UpdateFD.failure() }
        descriptor = fd
        do {
            var address = try Self.address(path)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { throw UpdateFD.failure() }
            var info = stat(); guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw UpdateAuthorizationError.invalidRequest }
            inode = info.st_ino
        } catch { Darwin.close(fd); throw error }
        DispatchQueue.global(qos: .utility).async { self.serve() }
    }
    func close() {
        lock.lock()
        closed = true
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
        unlinkOwnSocket()
    }
    private func unlinkOwnSocket() {
        var info = stat()
        if lstat(path, &info) == 0, info.st_uid == getuid(), info.st_ino == inode, info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
    }
    private func serve() {
        defer {
            lock.lock(); let fd = descriptor; descriptor = -1; closed = true; lock.unlock()
            if fd >= 0 { Darwin.close(fd) }; unlinkOwnSocket()
        }
        for _ in 0..<16 {
            lock.lock(); let stop = closed; let listener = descriptor; lock.unlock()
            if stop || listener < 0 { return }
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 600_000) > 0 else { return }
            lock.lock(); let wasClosed = closed; lock.unlock()
            if wasClosed { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            do {
                let peer = try Self.peer(client)
                guard peer.uid == 0, peer.pid > 1 else { continue }
                Self.timeouts(client)
                let provided = try Self.read(client, count: 64)
                guard provided == Data(digest.utf8) else { continue }
                var length = UInt32(bytes.count).bigEndian
                try withUnsafeBytes(of: &length) { try Self.write(client, data: Data($0)) }
                try Self.write(client, data: bytes)
                return
            } catch { continue }
        }
    }

    static func authenticateClient(_ invocation: UpdateAuthorizationInvocation, uid: uid_t) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UpdateFD.failure() }; defer { Darwin.close(fd) }
        timeouts(fd)
        var address = try address(path(uid: uid, pid: invocation.clientPID, id: invocation.transactionID))
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else { throw UpdateAuthorizationError.invalidClient }
        let identity = try peer(fd)
        guard identity.uid == uid, identity.pid == invocation.clientPID else { throw UpdateAuthorizationError.invalidClient }
        try write(fd, data: Data(invocation.requestDigest.utf8))
        let header = [UInt8](try read(fd, count: 4))
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 8_192 else { throw UpdateAuthorizationError.invalidRequest }
        let result = try read(fd, count: Int(length))
        guard UpdateAuthorizationPaths.digest(result) == invocation.requestDigest else { throw UpdateAuthorizationError.invalidRequest }
        return result
    }
    private static func path(uid: uid_t, pid: pid_t, id: UUID) -> String {
        "/private/tmp/orbit-upd-\(uid)-\(pid)-\(id.uuidString.lowercased()).sock"
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        guard path.utf8.count < 104 else { throw UpdateAuthorizationError.invalidRequest }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in path.withCString { source in strcpy(destination, source) } }
        }
        return address
    }
    private static func peer(_ fd: Int32) throws -> (uid: uid_t, pid: pid_t) {
        var uid: uid_t = 0; var gid: gid_t = 0; var pid: pid_t = 0; var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, size == MemoryLayout<pid_t>.size else { throw UpdateAuthorizationError.invalidClient }
        return (uid, pid)
    }
    private static func timeouts(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0); var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    private static func read(_ fd: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count); var offset = 0
        while offset < count {
            let amount = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            guard amount > 0 else { throw UpdateAuthorizationError.invalidClient }; offset += amount
        }
        return Data(bytes)
    }
    private static func write(_ fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard amount > 0 else { throw UpdateAuthorizationError.invalidClient }; offset += amount
        }
    }
}
