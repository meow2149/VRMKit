import Foundation

/// A mutable JSON tree that keeps extension fields available without a custom decoder.
public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([JSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    public subscript(key: String) -> JSON {
        get { object[key] ?? .null }
        set { var fields = object; fields[key] = newValue; self = .object(fields) }
    }

    public subscript(index: Int) -> JSON {
        get { array.indices.contains(index) ? array[index] : .null }
        set {
            var values = array
            guard values.indices.contains(index) else { return }
            values[index] = newValue
            self = .array(values)
        }
    }

    public var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var int: Int? {
        guard let v = number, v.isFinite, v.rounded(.towardZero) == v,
              v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public var float: Float? { number.map(Float.init) }
    public var isNull: Bool { self == .null }
    public var ints: [Int] { array.compactMap(\.int) }
    public var floats: [Float] { array.compactMap(\.float) }

    public static func integers(_ values: [Int]) -> JSON { .array(values.map { .number(Double($0)) }) }
    public static func floats(_ values: [Float]) -> JSON { .array(values.map { .number(Double($0)) }) }
    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
    public func data(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func vector3(default fallback: SIMD3<Float> = .zero) -> SIMD3<Float> {
        let v = floats
        if v.count >= 3 { return SIMD3(v[0], v[1], v[2]) }
        if !object.isEmpty { return SIMD3(self["x"].float ?? fallback.x, self["y"].float ?? fallback.y, self["z"].float ?? fallback.z) }
        return fallback
    }

    public func vector4(default fallback: SIMD4<Float> = SIMD4(repeating: 1)) -> SIMD4<Float> {
        let v = floats
        guard v.count >= 3 else { return fallback }
        return SIMD4(v[0], v[1], v[2], v.count > 3 ? v[3] : fallback.w)
    }
}

public enum VRMError: Error, LocalizedError, Sendable {
    case invalid(String)
    case unsupported(String)
    case missingResource(String)
    case index(String, Int)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): "Invalid asset: \(message)"
        case .unsupported(let message): "Unsupported feature: \(message)"
        case .missingResource(let name): "Missing resource: \(name)"
        case .index(let kind, let index): "Invalid \(kind) index: \(index)"
        }
    }
}

extension Array {
    func element(at index: Int, kind: String) throws -> Element {
        guard indices.contains(index) else { throw VRMError.index(kind, index) }
        return self[index]
    }
}

func checkedSum(_ a: Int, _ b: Int) throws -> Int {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow, value >= 0 else { throw VRMError.invalid("Byte range overflow") }
    return value
}

func checkedProduct(_ a: Int, _ b: Int) throws -> Int {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow, value >= 0 else { throw VRMError.invalid("Byte range overflow") }
    return value
}
