import Foundation

/// usuario con su nombre y rol, el rol lo decide el server
public struct Profile: Codable, Sendable {
    public let id: UUID
    public let displayName: String
    public let role: String

    public init(id: UUID = UUID(), displayName: String, role: String) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}
