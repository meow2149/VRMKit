import Foundation

public struct AccessorValues: Sendable {
    public let count: Int
    public let components: Int
    public let values: [Double]
    public var floats: [Float] { values.map(Float.init) }
    public subscript(element: Int, component: Int) -> Double { values[element * components + component] }
    public func vectors3() throws -> [SIMD3<Float>] {
        guard components == 3 else { throw VRMError.invalid("Expected VEC3 accessor") }
        return (0..<count).map { SIMD3(Float(self[$0, 0]), Float(self[$0, 1]), Float(self[$0, 2])) }
    }
    public func vectors4() throws -> [SIMD4<Float>] {
        guard components == 4 else { throw VRMError.invalid("Expected VEC4 accessor") }
        return (0..<count).map { SIMD4(Float(self[$0, 0]), Float(self[$0, 1]), Float(self[$0, 2]), Float(self[$0, 3])) }
    }
}

public extension Document {
    func accessor(_ index: Int) throws -> AccessorValues {
        let json = try entry("accessors", at: index)
        guard let count = json["count"].int, count >= 0, let type = json["type"].string,
              let componentType = json["componentType"].int else { throw VRMError.invalid("Accessor definition") }
        let size = try componentSize(componentType)
        let dimensions: (Int, Int)
        switch type {
        case "SCALAR": dimensions = (1, 1)
        case "VEC2": dimensions = (2, 1)
        case "VEC3": dimensions = (3, 1)
        case "VEC4": dimensions = (4, 1)
        case "MAT2": dimensions = (2, 2)
        case "MAT3": dimensions = (3, 3)
        case "MAT4": dimensions = (4, 4)
        default: throw VRMError.unsupported("Accessor type \(type)")
        }
        let (rows, columns) = dimensions, components = rows * columns
        let columnSize = columns > 1 ? (rows * size + 3) / 4 * 4 : rows * size
        let elementSize = columnSize * columns
        let offsets = (0..<columns).flatMap { col in (0..<rows).map { col * columnSize + $0 * size } }
        let normalized = json["normalized"].bool ?? false
        var values = Array(repeating: Double(0), count: try checkedProduct(count, components))
        if let viewIndex = json["bufferView"].int {
            let view = try entry("bufferViews", at: viewIndex), bytes = try bufferView(viewIndex)
            guard view["extensions"]["EXT_meshopt_compression"].isNull else { throw VRMError.unsupported("EXT_meshopt_compression") }
            let stride = view["byteStride"].int ?? elementSize, offset = json["byteOffset"].int ?? 0
            guard stride >= elementSize, stride % size == 0, offset >= 0 else { throw VRMError.invalid("Accessor layout") }
            if count > 0 {
                let end = try checkedSum(checkedSum(offset, checkedProduct(count - 1, stride)), elementSize)
                guard end <= bytes.count else { throw VRMError.invalid("Accessor exceeds buffer view") }
            }
            for element in 0..<count {
                for component in 0..<components {
                    values[element * components + component] = try readComponent(bytes, at: offset + element * stride + offsets[component], type: componentType, normalized: normalized)
                }
            }
        } else if json["sparse"].isNull, count > 0 { throw VRMError.invalid("Accessor has no bufferView or sparse values") }
        if !json["sparse"].isNull {
            let sparse = json["sparse"]
            guard let sparseCount = sparse["count"].int, sparseCount >= 0, sparseCount <= count,
                  let indicesView = sparse["indices"]["bufferView"].int,
                  let valuesView = sparse["values"]["bufferView"].int,
                  let indicesType = sparse["indices"]["componentType"].int,
                  [5121, 5123, 5125].contains(indicesType) else { throw VRMError.invalid("Sparse accessor") }
            let indices = try bufferView(indicesView), replacements = try bufferView(valuesView)
            let indexSize = try componentSize(indicesType), indexOffset = sparse["indices"]["byteOffset"].int ?? 0
            let valueOffset = sparse["values"]["byteOffset"].int ?? 0
            guard indexOffset >= 0, valueOffset >= 0,
                  try checkedSum(indexOffset, checkedProduct(sparseCount, indexSize)) <= indices.count,
                  try checkedSum(valueOffset, checkedProduct(sparseCount, elementSize)) <= replacements.count else { throw VRMError.invalid("Sparse byte ranges") }
            var previous = -1
            for item in 0..<sparseCount {
                let destination = Int(try readComponent(indices, at: indexOffset + item * indexSize, type: indicesType, normalized: false))
                guard destination > previous, destination < count else { throw VRMError.invalid("Sparse indices must increase and stay within count") }
                previous = destination
                for component in 0..<components {
                    values[destination * components + component] = try readComponent(replacements, at: valueOffset + item * elementSize + offsets[component], type: componentType, normalized: normalized)
                }
            }
        }
        return AccessorValues(count: count, components: components, values: values)
    }

    func indices(_ index: Int) throws -> [UInt32] {
        let definition = try entry("accessors", at: index)
        guard [5121, 5123, 5125].contains(definition["componentType"].int ?? 0),
              definition["normalized"].bool != true else { throw VRMError.invalid("Index component type") }
        let values = try accessor(index)
        guard values.components == 1 else { throw VRMError.invalid("Indices must be SCALAR") }
        return values.values.map { UInt32($0) }
    }
}

private func componentSize(_ type: Int) throws -> Int {
    switch type {
    case 5120, 5121: 1
    case 5122, 5123: 2
    case 5125, 5126: 4
    default: throw VRMError.unsupported("Component type \(type)")
    }
}

private func readComponent(_ data: Data, at offset: Int, type: Int, normalized: Bool) throws -> Double {
    let bytes = try data.slice(offset..<checkedSum(offset, componentSize(type)))
    let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    switch type {
    case 5120:
        let value = Double(Int8(bitPattern: UInt8(bits))); return normalized ? max(-1, value / 127) : value
    case 5121: return normalized ? Double(bits) / 255 : Double(bits)
    case 5122:
        let value = Double(Int16(bitPattern: UInt16(bits))); return normalized ? max(-1, value / 32767) : value
    case 5123: return normalized ? Double(bits) / 65535 : Double(bits)
    case 5125: return normalized ? Double(bits) / Double(UInt32.max) : Double(bits)
    case 5126:
        let value = Float(bitPattern: bits)
        guard value.isFinite else { throw VRMError.invalid("Non-finite accessor value") }; return Double(value)
    default: throw VRMError.unsupported("Component type \(type)")
    }
}
