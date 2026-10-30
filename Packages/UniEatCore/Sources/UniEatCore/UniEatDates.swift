import Foundation

/// fechas iso 8601 con o sin milisegundos como las manda la api
public enum UniEatDates {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()

            // primero con milisegundos, asi manda las fechas el server
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }

            // si no, sin milisegundos, asi quedan las que se guardan en el celular
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }

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
