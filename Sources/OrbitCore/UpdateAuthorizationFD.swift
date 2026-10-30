import Foundation
import Darwin

/// All privileged destination operations are relative to pinned, trusted directory descriptors.
enum UpdateFD {
    static func metadata(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw failure() }; return value
    }
    static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    static func failure() -> UpdateAuthorizationError { .io(String(cString: strerror(errno))) }
    static func noWriteACL(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return } // Darwin reports no extended ACL with ENOENT.
            throw UpdateAuthorizationError.unsafePermissions
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?; var position = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, position, &entry) == 0 {
            position = Int32(ACL_NEXT_ENTRY.rawValue)
            guard let entry else { throw UpdateAuthorizationError.unsafePermissions }
            var tag = ACL_UNDEFINED_TAG; var mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &mask) == 0 else { throw UpdateAuthorizationError.unsafePermissions }
            // write data/append/delete child/delete/write attrs/write xattrs/write ACL/change owner
            guard tag != ACL_EXTENDED_ALLOW || mask & 0x3574 == 0 else { throw UpdateAuthorizationError.unsafePermissions }
        }
    }
    static func openDirectory(_ url: URL, owners: Set<uid_t>, forbidWritable: Bool) throws -> Int32 {
        guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw UpdateAuthorizationError.invalidRequest }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        do {
            for part in url.pathComponents.dropFirst() {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure() }
                close(fd); fd = next
                let info = try metadata(fd)
                guard owners.contains(info.st_uid), !forbidWritable || info.st_mode & 0o022 == 0 else { throw UpdateAuthorizationError.unsafePermissions }
                if forbidWritable { try noWriteACL(fd) }
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func childDirectory(_ parent: Int32, name: String, owner: uid_t, mode: mode_t? = nil, create: Bool = false) throws -> Int32 {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw UpdateAuthorizationError.invalidRequest }
        var created = false
        if create {
            if mkdirat(parent, name, mode ?? 0o700) == 0 { created = true }
            else if errno != EEXIST { throw failure() }
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        do {
            let initial = try metadata(fd)
            guard initial.st_uid == owner else { throw UpdateAuthorizationError.unsafePermissions }
            if created { guard fchmod(fd, mode ?? 0o700) == 0 else { throw failure() } }
            let st = try metadata(fd)
            guard st.st_uid == owner, st.st_mode & 0o022 == 0, mode.map({ st.st_mode & 0o7777 == $0 }) ?? true else { throw UpdateAuthorizationError.unsafePermissions }
            try noWriteACL(fd); return fd
        } catch { close(fd); throw error }
    }
    static func readFile(_ parent: Int32, name: String, owner: uid_t, mode: mode_t, maximum: Int) throws -> Data {
        guard !name.contains("/"), name != ".", name != ".." else { throw UpdateAuthorizationError.invalidRequest }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        let before = try metadata(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == owner, before.st_nlink == 1,
              before.st_mode & 0o7777 == mode, before.st_size > 0, before.st_size <= maximum else { throw UpdateAuthorizationError.unsafePermissions }
        try noWriteACL(fd)
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size)); var offset = 0
        while offset < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            guard amount > 0 else { throw failure() }; offset += amount
        }
        guard same(before, try metadata(fd)) else { throw UpdateAuthorizationError.sourceChanged }
        return Data(bytes)
    }
    static func writeFile(_ parent: Int32, name: String, data: Data, mode: mode_t) throws {
        guard !name.contains("/"), name != ".", name != ".." else { throw UpdateAuthorizationError.invalidRequest }
        let temporary = ".write-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw failure() }
        do {
            var offset = 0
            while offset < data.count {
                let amount = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                guard amount > 0 else { throw failure() }; offset += amount
            }
            guard fchmod(fd, mode) == 0, fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0 else { throw failure() }
            fsync(parent); close(fd)
        } catch { close(fd); unlinkat(parent, temporary, 0); throw error }
    }
    static func exists(_ parent: Int32, _ name: String) -> Bool {
        var st = stat(); return fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0
    }
    static func entry(_ parent: Int32, _ name: String) throws -> stat {
        var st = stat(); guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }; return st
    }
    static func swap(_ first: Int32, _ firstName: String, _ second: Int32, _ secondName: String) throws {
        guard [firstName, secondName].allSatisfy({ !$0.contains("/") && $0 != "." && $0 != ".." }) else { throw UpdateAuthorizationError.invalidRequest }
        guard renameatx_np(first, firstName, second, secondName, UInt32(RENAME_SWAP)) == 0 else { throw failure() }
        fsync(first); fsync(second)
    }

    struct CopyBudget { var files = 0; var bytes: Int64 = 0; let deadline = ProcessInfo.processInfo.systemUptime + 300 }
    /// No copyfile/ditto follows an attacker-controlled source. Links are read as data and created only in our private tree.
    static func inspectOrCopy(_ source: Int32, destination: Int32?, owner: uid_t, rootOwned: Bool,
                              relative: [String] = [], budget: inout CopyBudget) throws {
        let before = try metadata(source)
        var volume = statfs()
        guard fstatfs(source, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw UpdateAuthorizationError.unsafePermissions }
        guard before.st_uid == owner, before.st_mode & S_IFMT == S_IFDIR,
              !rootOwned || before.st_mode & 0o022 == 0 else { throw UpdateAuthorizationError.unsafePermissions }
        if rootOwned { try noWriteACL(source) }
        guard let directory = fdopendir(dup(source)) else { throw failure() }
        defer { closedir(directory) }
        while let pointer = readdir(directory) {
            let name = withUnsafePointer(to: &pointer.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 }) else { throw UpdateAuthorizationError.invalidRequest }
            budget.files += 1
            guard budget.files <= 150_000, ProcessInfo.processInfo.systemUptime < budget.deadline else { throw AppUpdateInstallError.archiveTooLarge }
            let entry = try self.entry(source, name)
            guard entry.st_uid == owner, entry.st_mode & 0o6000 == 0,
                  !rootOwned || entry.st_mode & 0o022 == 0 || entry.st_mode & S_IFMT == S_IFLNK else { throw UpdateAuthorizationError.unsafePermissions }
            let type = entry.st_mode & S_IFMT
            if type == S_IFDIR {
                let input = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard input >= 0 else { throw failure() }; defer { close(input) }
                guard same(entry, try metadata(input)) else { throw UpdateAuthorizationError.sourceChanged }
                var output: Int32?
                if let destination {
                    guard mkdirat(destination, name, 0o700) == 0 else { throw failure() }
                    let fd = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw failure() }; output = fd
                }
                defer { if let output { close(output) } }
                try inspectOrCopy(input, destination: output, owner: owner, rootOwned: rootOwned, relative: relative + [name], budget: &budget)
                if let output { guard fchmod(output, 0o755) == 0 else { throw failure() } }
            } else if type == S_IFREG {
                guard entry.st_nlink == 1, entry.st_size >= 0, entry.st_size <= 2_147_483_648,
                      budget.bytes <= 8_589_934_592 - entry.st_size else { throw UpdateAuthorizationError.unsafePermissions }
                budget.bytes += entry.st_size
                let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard input >= 0 else { throw failure() }; defer { close(input) }
                guard same(entry, try metadata(input)) else { throw UpdateAuthorizationError.sourceChanged }
                if rootOwned { try noWriteACL(input) }
                if let destination {
                    var volume = statfs()
                    guard fstatfs(destination, &volume) == 0, UInt64(volume.f_bavail) * UInt64(volume.f_bsize) > UInt64(entry.st_size) + 134_217_728 else { throw AppUpdateInstallError.archiveTooLarge }
                    let output = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard output >= 0 else { throw failure() }; defer { close(output) }
                    var bytes = [UInt8](repeating: 0, count: 65_536); var total: Int64 = 0
                    while total < entry.st_size {
                        guard ProcessInfo.processInfo.systemUptime < budget.deadline else { throw AppUpdateInstallError.archiveTooLarge }
                        let amount = Darwin.read(input, &bytes, Int(min(Int64(bytes.count), entry.st_size - total)))
                        guard amount > 0 else { throw failure() }
                        var offset = 0
                        while offset < amount {
                            let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), amount - offset) }
                            guard written > 0 else { throw failure() }; offset += written
                        }
                        total += Int64(amount)
                    }
                    guard same(entry, try metadata(input)), fchmod(output, (entry.st_mode & 0o111 != 0) ? 0o755 : 0o644) == 0, fsync(output) == 0 else { throw UpdateAuthorizationError.sourceChanged }
                }
            } else if type == S_IFLNK {
                guard entry.st_nlink == 1 else { throw UpdateAuthorizationError.unsafePermissions }
                var bytes = [CChar](repeating: 0, count: 4097)
                let count = readlinkat(source, name, &bytes, 4096)
                guard count > 0, count < 4096 else { throw UpdateAuthorizationError.invalidRequest }
                bytes[count] = 0; let link = String(cString: bytes)
                guard !link.hasPrefix("/"), !link.contains("\\") else { throw UpdateAuthorizationError.invalidRequest }
                var resolved = relative
                for part in link.split(separator: "/") {
                    if part == "." { continue }
                    if part == ".." { guard !resolved.isEmpty else { throw UpdateAuthorizationError.invalidRequest }; resolved.removeLast() }
                    else { resolved.append(String(part)) }
                }
                if let destination, symlinkat(link, destination, name) != 0 { throw failure() }
                guard same(entry, try self.entry(source, name)) else { throw UpdateAuthorizationError.sourceChanged }
            } else { throw UpdateAuthorizationError.invalidRequest }
        }
        guard same(before, try metadata(source)) else { throw UpdateAuthorizationError.sourceChanged }
        if let destination { fsync(destination) }
    }
    static func removeOwnTree(_ parent: Int32, name: String, owner: uid_t) throws {
        guard !name.contains("/"), name != ".", name != ".." else { throw UpdateAuthorizationError.invalidRequest }
        let info = try entry(parent, name)
        guard info.st_uid == owner else { throw UpdateAuthorizationError.unsafePermissions }
        if info.st_mode & S_IFMT != S_IFDIR {
            guard unlinkat(parent, name, 0) == 0 else { throw failure() }; return
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard let directory = fdopendir(dup(fd)) else { throw failure() }; defer { closedir(directory) }
        var count = 0
        while let pointer = readdir(directory) {
            let child = withUnsafePointer(to: &pointer.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            if child == "." || child == ".." { continue }
            count += 1; guard count < 150_000 else { throw UpdateAuthorizationError.invalidState }
            try removeOwnTree(fd, name: child, owner: owner)
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw failure() }
    }

}
