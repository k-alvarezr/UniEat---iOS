import Foundation

/// fechas iso 8601 con o sin milisegundos como las manda la api
public enum UniEatDates {
    // un formatter por formato, se crean una sola vez y nunca se modifican
    // antes se creaba uno por cada fecha: 100 reportes eran unos 150 formatters
    // ISO8601DateFormatter es seguro entre hilos si no se le cambia nada, por eso el nonisolated(unsafe)
    nonisolated(unsafe) private static let withMilliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let withoutMilliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let text = try container.decode(String.self)

            // primero con milisegundos, asi manda las fechas el server
            if let date = withMilliseconds.date(from: text) { return date }

            // si no, sin milisegundos, asi quedan las que se guardan en el celular
            if let date = withoutMilliseconds.date(from: text) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(text)")
        }
        return decoder
    }
    public static func encoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }
}
