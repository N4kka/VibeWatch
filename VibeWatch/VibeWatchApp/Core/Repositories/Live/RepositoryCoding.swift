import Foundation

enum RepositoryCoding {
    static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(json.utf8)
        return try decoder.decode(type, from: data)
    }

    static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
