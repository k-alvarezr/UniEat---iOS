import Foundation

/// textos y fechas en español para mostrar, los valores internos siguen igual
enum SpanishPresentation {
    static let locale = Locale(identifier: "es_CO")

    // MARK: - dietas

    /// nombre de la dieta para mostrar, nil es que no se eligio ninguna
    static func diet(_ value: String?) -> String {
        guard let value else { return "Todas" }
        switch value {
        case "vegetarian": return "Vegetariana"
        case "vegan": return "Vegana"
        default: return "Otra preferencia"
        }
    }

    /// varias dietas juntas, por ejemplo "vegetariana, vegana"
    static func dietaryTags(_ values: [String]) -> String {
        values.map { diet($0).lowercased(with: locale) }.joined(separator: ", ")
    }

    // MARK: - fechas

    // un formatter por formato, se crean una sola vez y se reusan
    // crear uno en cada llamada es lento y el detalle y el feed muestran fechas cada minuto

    private static let dayAndMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE d 'de' MMMM"
        return formatter
    }()

    private static let dateAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        return formatter
    }()

    /// dia y mes, por ejemplo "sabado 25 de octubre", lo usa la cabecera de hoy
    static func dayAndMonth(_ date: Date) -> String {
        dayAndMonthFormatter.string(from: date)
    }

    /// fecha y hora, por ejemplo "25 oct 2026, 2:30 p. m.", para guardados, copia sin internet y vencimientos
    static func dateAndTime(_ date: Date) -> String {
        dateAndTimeFormatter.string(from: date)
    }

    /// solo la hora, por ejemplo "2:30 p. m.", para el detalle y los reportes
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
