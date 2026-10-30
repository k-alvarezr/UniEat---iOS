import Foundation
import UniEatCore

struct DetailLoadResult: Sendable {
    let detail: MenuDetail
    let cacheWarning: String?
}

/// lo de pedir y guardar el detalle sale del AppStore viejo a este servicio
/// lo usan los MenuDetailViewModel, uno por pantalla de detalle
@MainActor
final class MenuDetailService {
    private let api: APIRequesting
    private let session: SessionStore
    private let files: FileStore
    private let clock: ServerClock
    init(api: APIRequesting, session: SessionStore, files: FileStore, clock: ServerClock) {
        self.api = api
        self.session = session
        self.files = files
        self.clock = clock
    }
    /// trae la version actual del menu y guarda la copia en Caches (#33)
    /// si automatic es true el server no la cuenta en las metricas, son recargas que no hizo el usuario
    /// generation es la sesion con la que arranco la pantalla, si ya es otra se cancela
    func load(_ menu: DailyMenu, automatic: Bool, generation: UUID? = nil) async throws -> DetailLoadResult {
        guard let userID = session.profile?.id else { throw AuthFailure.expired }
        if let generation, generation != session.generation { throw CancellationError() }
        let expected = session.generation
        let query = automatic ? [URLQueryItem(name: "refresh", value: "auto")] : []
        let detail: MenuDetail = try await api.get("menus/\(menu.id.uuidString)", query: query)
        try Task.checkCancellation()
        guard session.matches(userID, generation: expected) else { throw CancellationError() }
        // la hora del server ajusta el reloj de la app
        clock.synchronize(detail.serverNow)
        var warning: String?
        do {
            try await files.save(detail, name: "detail-\(menu.id.uuidString)", folder: .caches,
                                 userId: userID, generation: expected)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warning = "El detalle se actualizó, pero no se pudo guardar su copia para usarla sin conexión."
        }
        guard session.matches(userID, generation: expected) else { throw CancellationError() }
        return DetailLoadResult(detail: detail, cacheWarning: warning)
    }
    /// lectura de la copia del detalle en segundo plano con Task.detached utility (#31), el disco y el json no traban la pantalla
    /// si cambio la sesion mientras se leia se bota el resultado
    func cached(_ menu: DailyMenu, generation: UUID? = nil) async -> MenuDetail? {
        guard let userID = session.profile?.id else { return nil }
        if let generation, generation != session.generation { return nil }
        let expected = session.generation
        let files = files
        let id = menu.id
        let detail = await Task.detached(priority: .utility) {
            try? await files.load(MenuDetail.self, name: "detail-\(id.uuidString)", folder: .caches, userId: userID)
        }.value
        guard session.matches(userID, generation: expected), !Task.isCancelled else { return nil }
        return detail
    }
}
