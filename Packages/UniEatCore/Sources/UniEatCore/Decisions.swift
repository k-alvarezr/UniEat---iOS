import Foundation

public enum PublicationState: Equatable, Sendable {
    case active
    case expiring
    case expired
}

public struct PublicationAssessment: Equatable, Sendable {
    public let state: PublicationState
    public let pendingReports: Int

    public init(menu: Menu, at date: Date = .now) {
        if !menu.isActive(at: date) {
            state = .expired
        } else if menu.validUntil.timeIntervalSince(date) <= 30 * 60 {
            state = .expiring
        } else {
            state = .active
        }
        pendingReports = menu.pendingReports
    }
}

public protocol FeedRankingStrategy {
    func ranked(_ menus: [Menu], for filters: FeedFilters, at date: Date) -> [Menu]
    func explanation(for menu: Menu, filters: FeedFilters, at date: Date) -> String
}

/// Local strategy for the offline/demo feed. The shared backend will make the
/// authoritative online decision once the team deploys it.
public struct ContextualRankingStrategy: FeedRankingStrategy {
    public init() {}

    public func ranked(_ menus: [Menu], for filters: FeedFilters, at date: Date = .now) -> [Menu] {
        menus.filter { menu in
            guard menu.isActive(at: date) else { return false }
            if let payment = filters.paymentMethod, !menu.paymentMethods.contains(payment) { return false }
            let walk = menu.area == filters.area ? 5 : 12
            if let minutes = filters.availableMinutes {
                if walk > minutes { return false }
                if menu.hasWaitEvidence(at: date), let wait = menu.waitMinutes, walk + wait > minutes {
                    return false
                }
            }
            return menu.items.contains { dish in
                let affordable = filters.budgetCop.map { dish.priceCop <= $0 } ?? true
                let matchesDiet = filters.diet.map { dish.dietaryKnown && dish.dietaryTags.contains($0) } ?? true
                return affordable && matchesDiet
            }
        }.sorted { lhs, rhs in
            let leftScore = score(lhs, filters: filters, at: date)
            let rightScore = score(rhs, filters: filters, at: date)
            if leftScore == rightScore { return lhs.publishedAt > rhs.publishedAt }
            return leftScore > rightScore
        }
    }

    public func explanation(for menu: Menu, filters: FeedFilters, at date: Date = .now) -> String {
        var reasons: [String] = []
        if let budget = filters.budgetCop,
           let dish = menu.items.filter({ item in
               item.priceCop <= budget &&
               (filters.diet.map { item.dietaryKnown && item.dietaryTags.contains($0) } ?? true)
           }).min(by: { $0.priceCop < $1.priceCop }) {
            reasons.append("\(dish.name) por $\(dish.priceCop) COP, dentro del presupuesto")
        }
        if let diet = filters.diet,
           menu.items.contains(where: { $0.dietaryKnown && $0.dietaryTags.contains(diet) }) {
            reasons.append("opción \(diet == "vegan" ? "vegana" : "vegetariana") declarada")
        }
        if let area = filters.area, menu.area == area { reasons.append("en la zona elegida") }
        if let minutes = filters.availableMinutes {
            if menu.hasWaitEvidence(at: date), let wait = menu.waitMinutes {
                let walk = menu.area == filters.area ? 5 : 12
                if walk + wait <= minutes { reasons.append("desplazamiento y fila estimados dentro de \(minutes) min") }
            } else {
                reasons.append("fila sin estimación suficiente")
            }
        }
        return reasons.isEmpty ? "Publicación vigente con información declarada" : reasons.joined(separator: " · ")
    }

    private func score(_ menu: Menu, filters: FeedFilters, at date: Date) -> Int {
        var value = menu.relevanceScore
        if let area = filters.area, area == menu.area { value += 30 }
        if let budget = filters.budgetCop, menu.lowestPriceCop <= budget { value += 10 }
        if let minutes = filters.availableMinutes, menu.hasWaitEvidence(at: date), let wait = menu.waitMinutes {
            let walk = menu.area == filters.area ? 5 : 12
            value += walk + wait <= minutes ? 10 : -20
        }
        value -= menu.pendingReports * 8
        return value
    }
}
