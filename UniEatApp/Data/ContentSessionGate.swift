import Foundation

/// Una invalidación debe ser inmediata aunque el actor aún tenga escrituras en cola.
/// El lock protege solo identidad/generación; todo SwiftData permanece en su actor.
final class ContentSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var configured = false
    private var userID: UUID?
    private var generation: UUID?
    private var revoked: Set<UUID> = []

    func setSession(userID: UUID?, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        configured = true
        self.userID = userID
        self.generation = generation
    }

    func revoke(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        revoked.insert(generation)
    }

    func permit(userID: UUID, generation: UUID?) -> ContentWritePermit {
        lock.lock()
        let expected = generation ?? (self.userID == userID ? self.generation : nil)
        let standalone = !configured && generation == nil
        lock.unlock()
        return ContentWritePermit { [self] in
            lock.lock(); defer { lock.unlock() }
            if standalone { return !configured }
            guard let expected else { return false }
            return !revoked.contains(expected) && self.userID == userID && self.generation == expected
        }
    }
}

struct ContentWritePermit: Sendable {
    let isValid: @Sendable () -> Bool
    func check() throws {
        guard isValid() else { throw CancellationError() }
    }
}
