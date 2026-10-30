import Foundation
import UniEatCore

@MainActor
final class PublishingService {
    private let api: APIRequesting
    let session: SessionStore
    private let files: FileStore
    init(api: APIRequesting, session: SessionStore, files: FileStore) {
        self.api = api; self.session = session; self.files = files
    }
    func mine() async throws -> [DailyMenu] { let response: MenusResponse = try await api.get("menus/mine"); return response.menus }
    func publish(_ body: MenuBody, replacing old: DailyMenu?) async throws {
        guard let id = body.establishmentId, session.approvedEstablishments.contains(where: { $0.id == id }) else {
            throw APIFailure(code: "VALIDATION_ERROR", message: "Selecciona un establecimiento aprobado.")
        }
        if let old { let _: MenuResponse = try await api.send("PUT", "menus/\(old.id.uuidString)", body: body) }
        else { let _: MenuResponse = try await api.send("POST", "menus", body: body) }
    }
    func close(_ menu: DailyMenu) async throws {
        let _: CloseResponse = try await api.send("POST", "menus/\(menu.id.uuidString)/close", body: NoBody?.none)
    }
    func saveDraft(_ draft: PublishDraft) {
        guard let id = session.profile?.id else { return }
        files.save(draft, name: "publish-draft", folder: .support, userId: id)
    }
    func loadDraft() -> PublishDraft? {
        guard let id = session.profile?.id else { return nil }
        return files.load(PublishDraft.self, name: "publish-draft", folder: .support, userId: id)
    }
    func clearDraft() {
        guard let id = session.profile?.id else { return }
        files.remove(name: "publish-draft", folder: .support, userId: id)
    }
}
