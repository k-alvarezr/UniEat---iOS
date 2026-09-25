import Foundation

/// Keeps visible labels and dates in Spanish while domain values remain stable.
enum SpanishPresentation {
    static let locale = Locale(identifier: "es_CO")

    static func diet(_ value: String?) -> String {
        guard let value else { return "Todas" }
        switch value {
        case "vegetarian": return "Vegetariana"
        case "vegan": return "Vegana"
        default: return "Otra preferencia"
        }
    }

    static func dietaryTags(_ values: [String]) -> String {
        values.map { diet($0).lowercased(with: locale) }.joined(separator: ", ")
    }

    static func dayAndMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE d 'de' MMMM"
        return formatter.string(from: date)
    }

    static func dateAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
