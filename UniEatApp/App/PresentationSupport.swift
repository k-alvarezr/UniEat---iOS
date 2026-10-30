import Combine
import Foundation
import UniEatCore

/// Forwards shared state changes without copying session/feed state into each screen.
@MainActor
class FeatureViewModel: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []
    func observe<T: ObservableObject>(_ object: T) {
        object.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}

enum LocalValues {
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? UniEatDates.encoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? UniEatDates.decoder().decode(type, from: data)
    }
}

/// Persisted with a cached response. Within one process elapsed time uses uptime.
struct ServerTimeReference: Codable, Sendable {
    let serverNow: Date
    let receivedAt: Date
}

@MainActor
final class ServerClock: ObservableObject {
    private var reference: ServerTimeReference?
    private var uptimeAtReceipt: TimeInterval = 0
    private let uptime: () -> TimeInterval
    private let wallTime: () -> Date
    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallTime: @escaping () -> Date = { .now }) {
        self.uptime = uptime
        self.wallTime = wallTime
    }
    var now: Date {
        guard let reference else { return wallTime() }
        return reference.serverNow.addingTimeInterval(max(0, uptime() - uptimeAtReceipt))
    }
    func synchronize(_ serverNow: Date) {
        objectWillChange.send()
        reference = ServerTimeReference(serverNow: serverNow, receivedAt: wallTime())
        uptimeAtReceipt = uptime()
    }
    func restore(_ saved: ServerTimeReference) {
        guard reference == nil else { return }
        synchronize(saved.serverNow.addingTimeInterval(max(0, wallTime().timeIntervalSince(saved.receivedAt))))
    }
    func snapshot() -> ServerTimeReference { ServerTimeReference(serverNow: now, receivedAt: wallTime()) }
}
