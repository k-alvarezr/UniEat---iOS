import Foundation
import UniEatCore

@MainActor
final class MenuDetailService {
    private let api: APIRequesting
    private let session: SessionStore
    private let files: FileStore
    private let clock: ServerClock
    init(api: APIRequesting, session: SessionStore, files: FileStore, clock: ServerClock) {
        self.api = api; self.session = session; self.files = files; self.clock = clock
    }
    func load(_ menu: DailyMenu, automatic: Bool) async throws -> MenuDetail {
        guard let userID = session.profile?.id else { throw AuthFailure.expired }
        let expected = session.generation
        let query = automatic ? [URLQueryItem(name: "refresh", value: "auto")] : []
        let detail: MenuDetail = try await api.get("menus/\(menu.id.uuidString)", query: query)
        try Task.checkCancellation()
        guard session.matches(userID, generation: expected) else { throw CancellationError() }
        clock.synchronize(detail.serverNow)
        files.save(detail, name: "detail-\(menu.id.uuidString)", folder: .caches, userId: userID)
        return detail
    }
    func cached(_ menu: DailyMenu) -> MenuDetail? {
        guard let userID = session.profile?.id else { return nil }
        return files.load(MenuDetail.self, name: "detail-\(menu.id.uuidString)", folder: .caches, userId: userID)
    }
}
