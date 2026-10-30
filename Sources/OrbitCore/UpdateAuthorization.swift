import Foundation
import CryptoKit
import Darwin

public enum UpdateAuthorizationOperation: String, Codable, Sendable { case install, restore }

public struct UpdateAuthorizationInvocation: Sendable {
    public let transactionID: UUID
    public let operation: UpdateAuthorizationOperation
    public let clientPID: Int32
    public let requestDigest: String
    public var arguments: [String] {
        ["--client", String(clientPID), "--operation", operation.rawValue,
         "--transaction", transactionID.uuidString.lowercased(), "--request-digest", requestDigest]
    }
    public init(transactionID: UUID, operation: UpdateAuthorizationOperation, clientPID: Int32, requestDigest: String) throws {
        guard clientPID > 1, requestDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw UpdateAuthorizationError.invalidRequest }
        self.transactionID = transactionID; self.operation = operation; self.clientPID = clientPID; self.requestDigest = requestDigest
    }
}

/// The caller presents macOS authentication and runs the fixed signed UpdateAgent.
/// Completion is read from a root-owned receipt, never trusted from process stdout.
public typealias UpdateAuthorizationRunner = @Sendable (UpdateAuthorizationInvocation) async throws -> Void

public enum UpdateAuthorizationError: LocalizedError {
    case invalidRequest, invalidClient, unsafePermissions, sourceChanged, busy, invalidState, receiptUnavailable, cancelled, administratorRequired, runningApplication, unsupportedTarget, io(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "授权安装请求不完整、过期或已变化。"
        case .invalidClient: return "无法验证 Orbit 或授权安装组件的签名与运行身份。"
        case .unsafePermissions: return "应用或授权目录存在可变权限，无法安全执行管理员替换。"
        case .sourceChanged: return "应用或安装副本已变化，未覆盖当前内容。"
        case .busy: return "另一项管理员更新正在执行。"
        case .invalidState: return "管理员更新记录不处于可执行状态。"
        case .receiptUnavailable: return "尚未取得可核验的管理员更新回执，请重试核对状态。"
        case .cancelled: return "管理员认证已取消。"
        case .administratorRequired: return "此操作需要通过 macOS 管理员认证。"
        case .runningApplication: return "应用或其中的进程仍在运行，请退出后重试。"
        case .unsupportedTarget: return "管理员安装仅支持 /Applications 中受保护的普通 App，无法处理此目标。"
        case .io(let message): return "管理员安装步骤失败：\(message)"
        }
    }
}

public struct UpdateAuthorizationReceipt: Codable, Sendable {
    public let transactionID: UUID
    public let clientUID: UInt32
    public let targetLeaf: String
    public let identifier: String
    public let originalHash: String
    public let replacementHash: String
    public let originalBuild: String
    public let replacementBuild: String
    public let state: AppUpdateInstallationState
    public let message: String
    public let completedAt: Date
    public let requestDigest: String?
    public var backupURL: URL {
        UpdateAuthorizationPaths.transactions.appendingPathComponent(transactionID.uuidString.lowercased()).appendingPathComponent("backup.app")
    }

    func isCurrent(after intent: Date?, requestDigest expectedDigest: String?) -> Bool {
        guard let intent else { return true }
        return completedAt >= intent && requestDigest == expectedDigest
    }

    public static func read(_ id: UUID, clientUID: UInt32 = getuid()) throws -> UpdateAuthorizationReceipt? {
        let directory = UpdateAuthorizationPaths.receipts.appendingPathComponent(String(clientUID))
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let fd = try UpdateFD.openDirectory(directory, owners: [0], forbidWritable: true)
        defer { close(fd) }
        let name = id.uuidString.lowercased() + ".json"
        var metadata = stat()
        if fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return nil }
        let data = try UpdateFD.readFile(fd, name: name, owner: 0, mode: 0o644, maximum: 16_384)
        let result = try JSONDecoder().decode(UpdateAuthorizationReceipt.self, from: data)
        guard result.transactionID == id, result.clientUID == clientUID, UpdateAuthorizationRequest.validLeaf(result.targetLeaf) else { throw UpdateAuthorizationError.invalidRequest }
        return result
    }
}

struct UpdateAuthorizationRequest: Codable, Sendable {
    let id: UUID
    let operation: UpdateAuthorizationOperation
    let targetLeaf: String
    let originalHash: String
    let replacementHash: String
    let issuedAt: Date
    func validate(id: UUID, operation: UpdateAuthorizationOperation, now: Date = Date()) throws {
        let age = now.timeIntervalSince(issuedAt)
        guard self.id == id, self.operation == operation, Self.validLeaf(targetLeaf), age >= -5, age < 600,
              [originalHash, replacementHash].allSatisfy({ Data(base64Encoded: $0).map { [20, 32].contains($0.count) } ?? false }) else { throw UpdateAuthorizationError.invalidRequest }
    }
    static func validLeaf(_ value: String) -> Bool {
        !value.hasPrefix(".") && value.hasSuffix(".app") && value.utf8.count <= 255 && value.count > 4
            && !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains { $0.value < 32 }
    }
}

enum UpdateAuthorizationPaths {
    static let transactions = URL(fileURLWithPath: "/Library/Application Support/Orbit/UpdateAgent")
    static let receipts = URL(fileURLWithPath: "/Library/Application Support/Orbit/UpdateReceipts")
    static func requests(home: URL) -> URL { home.appendingPathComponent("Library/Application Support/Orbit/UpdateRequests") }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
