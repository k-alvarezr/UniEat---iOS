import Foundation

/// filtros del estudiante para el feed BQ-03: presupuesto, minutos, dieta, zona y pago
public struct FeedFilters: Codable, Hashable, Sendable {
    public var budgetCop: Int?
    public var availableMinutes: Int?
    public var diet: String?
    public var area: String?
    public var paymentMethod: String?

    public init(budgetCop: Int? = 20_000, availableMinutes: Int? = 40, diet: String? = nil,
                area: String? = "Centro", paymentMethod: String? = nil) {
        self.budgetCop = budgetCop
        self.availableMinutes = availableMinutes
        self.diet = diet
        self.area = area
        self.paymentMethod = paymentMethod
    }
}
