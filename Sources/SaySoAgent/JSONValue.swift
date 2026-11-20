import Foundation

/// Valor JSON genérico: entradas de herramientas, esquemas y cuerpos de petición.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Valor JSON no reconocido")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .number(v):
            // Enteros sin «.0» para que los servidores estrictos los acepten.
            if v.rounded() == v, abs(v) < 9_007_199_254_740_992 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }

    // MARK: Conversión

    /// Analiza datos JSON.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Analiza un texto JSON.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Serializa a datos JSON (claves ordenadas, salida estable).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Serializa a texto JSON.
    public func jsonString() -> String {
        (try? encoded()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: Acceso

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? { if case let .string(v) = self { return v }; return nil }
    public var doubleValue: Double? { if case let .number(v) = self { return v }; return nil }
    public var boolValue: Bool? { if case let .bool(v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }

    /// Entero exacto (acepta también números en texto).
    public var intValue: Int? {
        switch self {
        case let .number(v): return v.rounded() == v && abs(v) < 1e15 ? Int(v) : nil
        case let .string(s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSONValue {
    /// Esquema JSON de objeto: `{"type":"object","properties":…,"required":…}`.
    static func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    /// Propiedad de esquema con tipo y descripción.
    static func property(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }
}
