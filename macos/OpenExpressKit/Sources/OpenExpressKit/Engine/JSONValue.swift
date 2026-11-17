import Foundation

/// Any JSON value: the `params` and `result` of the engine protocol (docs/ENGINE.md) before
/// they are decoded into a model, and fields whose shape the protocol leaves open.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .number(let d) where d.rounded() == d && abs(d) < 9.0e15: Int(d)
        case .string(let s): Int(s)
        default: nil
        }
    }

    public var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            if d.rounded() == d, abs(d) < 9.0e15 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// Decodes this value into a model (snake_case keys, ISO 8601 dates with offset).
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try EngineCoding.decoder().decode(T.self, from: data)
    }

    /// The JSON value of any encodable model (snake_case keys).
    public init(encoding value: some Encodable) throws {
        let data = try EngineCoding.encoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// The coding conventions of the engine: snake_case keys, ISO 8601 times with an offset,
/// with or without fractional seconds (Python's `isoformat()` writes microseconds).
public enum EngineCoding {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "Not an ISO 8601 date: \(s)")
            }
            return date
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// "2026-11-17T09:41:00+01:00", "…T09:41:00.123456+01:00", "…T08:41:00Z".
    public static func parseDate(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        // Drop the fraction, keep its value: the format style takes at most milliseconds.
        guard let dot = s.firstIndex(of: "."), s[s.index(after: dot)...].first?.isNumber == true
        else { return nil }
        let digitsEnd = s[s.index(after: dot)...].firstIndex(where: { !$0.isNumber }) ?? s.endIndex
        let fraction = Double("0" + s[dot..<digitsEnd]) ?? 0
        let whole = String(s[..<dot]) + String(s[digitsEnd...])
        guard let base = try? Date(whole, strategy: .iso8601) else { return nil }
        return base.addingTimeInterval(fraction)
    }
}
