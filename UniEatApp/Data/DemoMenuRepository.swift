import Foundation
import UniEatCore

@MainActor
protocol MenuRepository {
    func loadMenus() async throws -> [Menu]
    func saveMenu(_ menu: Menu) async throws
}

@MainActor
final class DemoMenuRepository: MenuRepository {
    private let storageKey = "unieat.demo.published-menus.v2"

    func loadMenus() async throws -> [Menu] {
        let localMenus = storedMenus()
        // Sample publications are regenerated for each demo launch so an old
        // installation still opens with current examples; user publications persist.
        return localMenus + SampleMenus.all
    }

    func saveMenu(_ menu: Menu) async throws {
        var menus = storedMenus()
        if let index = menus.firstIndex(where: { $0.id == menu.id }) {
            menus[index] = menu
        } else {
            menus.insert(menu, at: 0)
        }
        let data = try UniEatDates.encoder().encode(menus)
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func storedMenus() -> [Menu] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let menus = try? UniEatDates.decoder().decode([Menu].self, from: data) else { return [] }
        return menus
    }
}

enum SampleMenus {
    private static let firstID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private static let secondID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private static let thirdID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!

    static var all: [Menu] {
        let until = Date.now.addingTimeInterval(5 * 60 * 60)
        let earlier = Date.now.addingTimeInterval(-35 * 60)
        return [
            Menu(id: firstID, title: "Almuerzo completo", validUntil: until, publishedAt: earlier,
                 establishmentName: "Ajíaco y Fríjoles", area: "Centro", address: "Calle 19 #1-21",
                 entranceDescription: "Entrada junto a la plazoleta", latitude: 4.6028, longitude: -74.0652,
                 paymentMethods: ["Nequi", "Efectivo"], isVerified: false,
                 items: [MenuDish(name: "Ajíaco santafereño", description: "Con arroz, aguacate y crema", priceCop: 14_500,
                                 dietaryTags: [], dietaryKnown: true),
                         MenuDish(name: "Bandeja fríjol campesino", priceCop: 15_000, dietaryKnown: true)],
                 lowestPriceCop: 14_500, waitMinutes: 8, waitSampleCount: 4,
                 waitNewestReportAt: Date.now.addingTimeInterval(-8 * 60), relevanceScore: 30,
                 explanation: "Cerca del área elegida y dentro del presupuesto"),
            Menu(id: secondID, title: "Bowl completo", validUntil: until, publishedAt: earlier.addingTimeInterval(-600),
                 establishmentName: "Bowls Centro Cívico", area: "Centro", address: "Carrera 1 #18A-70",
                 entranceDescription: "Local junto a la esquina del bloque B", latitude: 4.6036, longitude: -74.0640,
                 paymentMethods: ["Nequi", "Tarjeta"], isVerified: false,
                 items: [MenuDish(name: "Bowl de hummus", description: "Vegetales, garbanzo y arroz", priceCop: 12_000,
                                 dietaryTags: ["vegetarian", "vegan"], dietaryKnown: true),
                         MenuDish(name: "Bowl de pollo teriyaki", priceCop: 14_000, dietaryKnown: true)],
                 lowestPriceCop: 12_000, waitMinutes: nil, waitSampleCount: 1,
                 relevanceScore: 20, explanation: "Opción vegetariana con precio declarado"),
            Menu(id: thirdID, title: "Almuerzo casero", validUntil: until, publishedAt: earlier.addingTimeInterval(-1200),
                 establishmentName: "Doña Elvira", area: "Norte", address: "Calle 21 #2-15",
                 entranceDescription: "Fachada amarilla", latitude: 4.6054, longitude: -74.0628,
                 paymentMethods: ["Efectivo", "Daviplata"], isVerified: false,
                 items: [MenuDish(name: "Arroz con pollo", priceCop: 13_000, dietaryKnown: true),
                         MenuDish(name: "Sopa de verduras", priceCop: 9_000,
                                  dietaryTags: ["vegetarian"], dietaryKnown: true)],
                 lowestPriceCop: 9_000, waitMinutes: 5, waitSampleCount: 3,
                 waitNewestReportAt: Date.now.addingTimeInterval(-15 * 60), pendingReports: 1,
                 relevanceScore: 10, explanation: "Precio bajo; hay un reporte pendiente")
        ]
    }
}
