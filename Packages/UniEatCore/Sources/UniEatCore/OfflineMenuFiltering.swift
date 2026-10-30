import Foundation

/// filtra sin red el catalogo guardado con los mismos criterios que rank-v1
/// puede decir si un menu es compatible, pero no que siga disponible ni en que orden va
public enum OfflineMenuFiltering {
    public static func filter(_ menus: [DailyMenu], filters: FeedFilters, at date: Date) -> [DailyMenu] {
        menus.filter { menu in
            guard menu.isActive(at: date) else { return false }
            if let payment = filters.paymentMethod, !menu.paymentMethods.contains(payment) { return false }
            guard menu.items.contains(where: { dish in
                (filters.budgetCop == nil || dish.priceCop <= filters.budgetCop!) &&
                (filters.diet == nil || (dish.dietaryKnown && dish.dietaryTags.contains(filters.diet!)))
            }) else { return false }
            if let area = filters.area, let available = filters.availableMinutes {
                let travel = menu.area == area ? 5 : 12   // minutos caminando aproximados, la misma regla de rank-v1
                if travel > available { return false }
                if menu.hasWaitEvidence(at: date), travel + (menu.waitMinutes ?? 0) > available { return false }
            }
            return true
        }.map {
            $0.replacing(explanation: "Compatible según la copia guardada. La disponibilidad y el orden se actualizarán al recuperar conexión.")
        }
    }
}

public extension DailyMenu {
    /// copia del menu cambiando solo los platos o la explicacion, el resto (id, version, ubicacion) queda igual
    func replacing(items: [MenuDish]? = nil, explanation: String? = nil) -> DailyMenu {
        DailyMenu(id: id, title: title, version: version, validUntil: validUntil, publishedAt: publishedAt,
            closedAt: closedAt, establishmentId: establishmentId, establishmentName: establishmentName,
            area: area, address: address, entranceDescription: entranceDescription, latitude: latitude,
            longitude: longitude, photoUrl: photoUrl, paymentMethods: paymentMethods, isVerified: isVerified,
            items: items ?? self.items, lowestPriceCop: lowestPriceCop, waitMinutes: waitMinutes,
            waitSampleCount: waitSampleCount, waitNewestReportAt: waitNewestReportAt,
            pendingReports: pendingReports, explanation: explanation ?? self.explanation)
    }
}
