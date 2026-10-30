import Foundation
import CryptoKit
import Security
import OrbitCore

enum PrivilegedTool: String, Sendable {
    case fan = "OrbitFanAgent", update = "OrbitUpdateAgent"
    var identifier: String { self == .fan ? "com.orbitmac.Orbit.FanAgent" : "com.orbitmac.Orbit.UpdateAgent" }
}

/// Stages only the two bundled, developer-signed components. Their own root entry points
/// independently validate the client and fixed operation; this launcher cannot run arbitrary tools.
struct PrivilegedToolLauncher: Sendable {
    private let tool: PrivilegedTool
    private let source: URL
    private let digest: String
    private let requirement: String

    init(_ tool: PrivilegedTool, bundleURL: URL = Bundle.main.bundleURL) throws {
        self.tool = tool
        let authority = try Self.runningGUIAuthority()
        // Re-open the outer bundle so a swapped helper invalidates its resource seal.
        var outer: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &outer) == errSecSuccess, let outer,
              SecStaticCodeCheckValidity(outer, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), authority.requirement) == errSecSuccess else {
            throw userError("Orbit 应用文件或系统组件已变化，未请求管理员权限。请重新安装完整构建。")
        }
        source = bundleURL.appendingPathComponent("Contents/Helpers/" + tool.rawValue)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(source as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw userError("系统组件的签名未通过，请重新构建 Orbit。")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoIdentifier as String] as? String == tool.identifier,
              values[kSecCodeInfoTeamIdentifier as String] as? String == authority.team else {
            throw userError("系统组件与 Orbit 的开发者身份不一致，未请求管理员权限。")
        }
        requirement = "anchor apple generic and identifier \"\(tool.identifier)\" and certificate leaf[subject.OU] = \"\(authority.team)\""
        var expected: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), expected) == errSecSuccess else {
            throw userError("系统组件的开发者身份未通过。")
        }
        digest = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
    }

    private static func runningGUIAuthority() throws -> (team: String, requirement: SecRequirement) {
        var running: SecCode?
        var disk: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopyStaticCode(running, [], &disk) == errSecSuccess, let disk else {
            throw userError("无法确认正在运行的 Orbit 身份。")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(disk, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == "com.orbitmac.Orbit",
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw userError("此操作需要开发者签名的 Orbit 构建。")
        }
        let text = "anchor apple generic and identifier \"com.orbitmac.Orbit\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw userError("正在运行的 Orbit 开发者身份未通过。")
        }
        return (team, requirement)
    }

    func command(arguments: [String], timeout: TimeInterval) throws -> MaintenanceCommand {
        guard arguments.count <= 12, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }) else { throw userError("系统操作参数无效。") }
        let installed = "/Library/PrivilegedHelperTools/" + tool.identifier
        let shell = "set -eu\n" +
            "test ! -L /Library/PrivilegedHelperTools\n" +
            "test ! -L \(Self.quote(installed))\n" +
            "stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.OrbitPrivilege.XXXXXXXX)\n" +
            "trap '/bin/rm -rf -- \"$stage\"' EXIT\n" +
            "/bin/cp \(Self.quote(source.path)) \"$stage/agent\"\n" +
            "actual=$(/usr/bin/shasum -a 256 \"$stage/agent\" | /usr/bin/cut -d ' ' -f 1)\n" +
            "test \"$actual\" = \(Self.quote(digest))\n" +
            "/usr/bin/codesign " + Self.signatureCheckArguments(requirement: requirement).map(Self.quote).joined(separator: " ") + " \"$stage/agent\"\n" +
            "/usr/sbin/chown root:wheel \"$stage/agent\"\n/bin/chmod 755 \"$stage/agent\"\n" +
            "/bin/mv -f \"$stage/agent\" \(Self.quote(installed))\n" +
            Self.quote(installed) + " " + arguments.map(Self.quote).joined(separator: " ")
        return MaintenanceCommand(executable: "/usr/bin/osascript", arguments: ["-e", "do shell script " + Self.scriptString(shell) + " with administrator privileges"], timeoutSeconds: timeout)
    }
    static func signatureCheckArguments(requirement: String) -> [String] { ["--verify", "--strict", "-R=" + requirement] }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func scriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
