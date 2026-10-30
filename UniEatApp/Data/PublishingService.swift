import Foundation
import UniEatCore

/// publicar, cerrar y el borrador salen del AppStore viejo a este servicio
/// el borrador sigue siendo el archivo en Application Support de #33
@MainActor
final class PublishingService {
    private let api: APIRequesting
    let session: SessionStore
    private let files: FileStore
    private var draftRevision: UInt64 = 0
    init(api: APIRequesting, session: SessionStore, files: FileStore) {
        self.api = api
        self.session = session
        self.files = files
    }
    /// menus del restaurante, para editarlos o cerrarlos
    func mine() async throws -> [DailyMenu] {
        try session.requireVerifiedAccount()
        let response: MenusResponse = try await api.get("menus/mine")
        return response.menus
    }
    /// crea un menu o una version nueva de old, al editar va la version que vio el dueño
    /// si alguien mas lo edito el server responde VERSION_CONFLICT y no se pisan los cambios
    func publish(_ body: MenuBody, replacing old: DailyMenu?) async throws {
        try session.requireVerifiedAccount()
        guard let id = body.establishmentId, session.approvedEstablishments.contains(where: { $0.id == id }) else {
            throw APIFailure(code: "VALIDATION_ERROR", message: "Selecciona un establecimiento aprobado.")
        }
        if let old { let _: MenuResponse = try await api.send("PUT", "menus/\(old.id.uuidString)", body: body) }
        else { let _: MenuResponse = try await api.send("POST", "menus", body: body) }
    }
    /// cierra el menu antes de que venza, el historial se queda
    func close(_ menu: DailyMenu) async throws {
        try session.requireVerifiedAccount()
        let _: CloseResponse = try await api.send("POST", "menus/\(menu.id.uuidString)/close", body: NoBody?.none)
    }
    /// La foto del formulario queda ligada a la cuenta y generación que la originó.
    func saveDraft(_ draft: PublishDraft, userID: UUID, generation: UUID) async throws {
        guard session.matches(userID, generation: generation) else { throw CancellationError() }
        draftRevision += 1
        let revision = draftRevision
        try await files.save(draft, name: "publish-draft", folder: .support, userId: userID, generation: generation, revision: revision)
        guard session.matches(userID, generation: generation) else { throw CancellationError() }
    }
    /// El actor ordena lectura/escritura; una sesión distinta descarta la lectura.
    /// si cambio la sesion mientras se leia se bota el resultado
    func loadDraft() async throws -> PublishDraft? {
        guard let id = session.profile?.id else { return nil }
        let expected = session.generation, files = files
        let draft = try await Task.detached(priority: .utility) {
            try await files.load(PublishDraft.self, name: "publish-draft", folder: .support, userId: id)
        }.value
        guard session.matches(id, generation: expected), !Task.isCancelled else { return nil }
        return draft
    }
    /// borra el borrador despues de publicar
    func clearDraft(userID: UUID, generation: UUID) async throws {
        guard session.matches(userID, generation: generation) else { throw CancellationError() }
        draftRevision += 1
        let revision = draftRevision
        try await files.remove(name: "publish-draft", folder: .support, userId: userID, generation: generation, revision: revision)
    }
}
