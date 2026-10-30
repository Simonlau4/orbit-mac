import XCTest
import OrbitCore
@testable import Orbit

final class PrivilegedToolLauncherTests: XCTestCase {
    func testCodesignRequirementIsParsedAndEnforcedBeforeElevation() async {
        let valid = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/codesign", arguments: PrivilegedToolLauncher.signatureCheckArguments(requirement: "anchor apple") + ["/usr/bin/true"], timeoutSeconds: 3))
        XCTAssertEqual(valid.exitCode, 0, valid.output)
        let invalid = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/codesign", arguments: PrivilegedToolLauncher.signatureCheckArguments(requirement: "identifier \"com.orbitmac.Orbit.must.not.match\"") + ["/usr/bin/true"], timeoutSeconds: 3))
        XCTAssertNotEqual(invalid.exitCode, 0)
        XCTAssertTrue(invalid.output.contains("requirement"), invalid.output)
        XCTAssertFalse(invalid.output.contains("No such file"), invalid.output)
    }
    func testShellArgumentsRemainLiteralIncludingQuotesAndCommandSubstitution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("must-not-exist")
        let inputs = ["plain", "with spaces", "' ; /usr/bin/touch " + marker.path + "; #", "$(/usr/bin/touch " + marker.path + ")", "line\nnext", "`ignored`", "quote\"\\"]
        let shell = "/usr/bin/printf '%s\\0' " + inputs.map(PrivilegedToolLauncher.quote).joined(separator: " ")
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: "/bin/sh", arguments: ["-c", shell], timeoutSeconds: 3))
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(Array(result.output.components(separatedBy: "\0").dropLast()), inputs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testAppleScriptStringRoundTripNeverExecutesTheShellText() async {
        let source = "set -eu\nprintf '%s' \"quoted\\value\"\n'$(this remains literal)'"
        let result = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/osascript", arguments: ["-e", "return " + PrivilegedToolLauncher.scriptString(source)], timeoutSeconds: 3))
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output.trimmingCharacters(in: .newlines), source)
    }
    func testMissingOrAdhocHelpersAreRejectedBeforeAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-helper-" + UUID().uuidString)
        let helpers = root.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try PrivilegedToolLauncher(.fan, bundleURL: root))
        let helper = helpers.appendingPathComponent("OrbitFanAgent")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper)
        let signed = await MaintenanceService.execute(MaintenanceCommand(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--identifier", "com.orbitmac.Orbit.FanAgent", helper.path], timeoutSeconds: 3))
        XCTAssertEqual(signed.exitCode, 0, signed.output)
        XCTAssertThrowsError(try PrivilegedToolLauncher(.fan, bundleURL: root))
    }
}
