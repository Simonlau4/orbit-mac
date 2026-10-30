import Foundation
import Darwin

/// A short-lived request, never a shell command or an arbitrary hardware key.
public struct FanControlLease: Codable, Sendable {
    public let id: UUID
    public let mode: FanCoolingMode
    public let issuedAt: Date
    public init(id: UUID, mode: FanCoolingMode, issuedAt: Date = Date()) {
        self.id = id; self.mode = mode; self.issuedAt = issuedAt
    }
    public func valid(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        return age >= -2 && age < 10
    }
}

public struct FanControlReport: Codable, Sendable {
    public let mode: FanCoolingMode
    public let message: String
    public let restored: Bool
    public let sampledAt: Date
    public init(mode: FanCoolingMode, message: String, restored: Bool) {
        self.mode = mode; self.message = message; self.restored = restored; sampledAt = Date()
    }
}
