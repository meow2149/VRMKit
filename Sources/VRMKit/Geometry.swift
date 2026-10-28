import Foundation

public struct MorphTarget: Sendable {
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
}

public struct Primitive: Sendable {
    public let material: Int?
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let texcoords: [[SIMD2<Float>]]
    public let colors: [SIMD4<Float>]
    public let triangles: [UInt32]
    public let jointSets: [[SIMD4<UInt32>]]
    public let weightSets: [[SIMD4<Float>]]
    public let targets: [MorphTarget]
}

public struct Geometry: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var texcoords: [SIMD2<Float>]
    public var colors: [SIMD4<Float>]
    public var triangles: [UInt32]
    public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [], texcoords: [SIMD2<Float>] = [], colors: [SIMD4<Float>] = [], triangles: [UInt32]) {
        self.positions = positions; self.normals = normals; self.texcoords = texcoords; self.colors = colors; self.triangles = triangles
    }
}

public struct Skin: Sendable {
    public let joints: [Int]
    public let inverseBind: [Matrix4]
}

public extension Document {
    func mesh(_ index: Int) throws -> [Primitive] {
        try entry("meshes", at: index)["primitives"].array.map { primitive in
            guard primitive["extensions"]["KHR_draco_mesh_compression"].isNull else { throw VRMError.unsupported("KHR_draco_mesh_compression") }
            let attributes = primitive["attributes"]
            guard let position = attributes["POSITION"].int else { throw VRMError.invalid("Mesh has no POSITION") }
            let positions = try accessor(position).vectors3(), count = positions.count
            guard count > 0, count <= Int(UInt32.max) else { throw VRMError.invalid("Vertex count") }
            func vectors3(_ key: String) throws -> [SIMD3<Float>] {
                guard let index = attributes[key].int else { return [] }
                let values = try accessor(index).vectors3()
                guard values.count == count else { throw VRMError.invalid("\(key) count differs from POSITION") }; return values
            }
            let indices = try primitive["indices"].int.map { try self.indices($0) } ?? (0..<count).map(UInt32.init)
            guard indices.allSatisfy({ Int($0) < count }) else { throw VRMError.invalid("Triangle index exceeds vertex count") }
            var triangles: [UInt32] = []
            switch primitive["mode"].int ?? 4 {
            case 4:
                guard indices.count % 3 == 0 else { throw VRMError.invalid("Triangle index count") }; triangles = indices
            case 5:
                if indices.count >= 3 {
                    for i in 2..<indices.count {
                        triangles += i % 2 == 0 ? [indices[i - 2], indices[i - 1], indices[i]] : [indices[i - 1], indices[i - 2], indices[i]]
                    }
                }
            case 6:
                if indices.count >= 3 { for i in 2..<indices.count { triangles += [indices[0], indices[i - 1], indices[i]] } }
            default: throw VRMError.unsupported("Non-triangle primitive")
            }
            var texcoords: [[SIMD2<Float>]] = []
            let uvKeys = attributes.object.keys.filter { $0.hasPrefix("TEXCOORD_") }.compactMap { Int($0.dropFirst(9)) }
            for set in 0..<(uvKeys.max().map { $0 + 1 } ?? 0) {
                if let index = attributes["TEXCOORD_\(set)"].int {
                    let values = try accessor(index)
                    guard values.count == count, values.components == 2 else { throw VRMError.invalid("Texture coordinate accessor") }
                    texcoords.append((0..<count).map { SIMD2(Float(values[$0, 0]), Float(values[$0, 1])) })
                } else { texcoords.append(Array(repeating: .zero, count: count)) }
            }
            var colors: [SIMD4<Float>] = []
            if let index = attributes["COLOR_0"].int {
                let values = try accessor(index)
                guard values.count == count, [3, 4].contains(values.components) else { throw VRMError.invalid("Vertex color accessor") }
                colors = (0..<count).map { SIMD4(Float(values[$0, 0]), Float(values[$0, 1]), Float(values[$0, 2]), values.components == 4 ? Float(values[$0, 3]) : 1) }
            }
            var jointSets: [[SIMD4<UInt32>]] = [], weightSets: [[SIMD4<Float>]] = []
            let jointKeys = attributes.object.keys.filter { $0.hasPrefix("JOINTS_") }.compactMap { Int($0.dropFirst(7)) }.sorted()
            for set in jointKeys {
                guard let joint = attributes["JOINTS_\(set)"].int, let weight = attributes["WEIGHTS_\(set)"].int else { throw VRMError.invalid("Joint attributes need matching weights") }
                let joints = try accessor(joint), weights = try accessor(weight).vectors4()
                guard joints.count == count, joints.components == 4, weights.count == count,
                      joints.values.allSatisfy({ $0 >= 0 && $0 <= Double(UInt32.max) && $0.rounded() == $0 }) else { throw VRMError.invalid("Skin attributes") }
                jointSets.append((0..<count).map { SIMD4(UInt32(joints[$0, 0]), UInt32(joints[$0, 1]), UInt32(joints[$0, 2]), UInt32(joints[$0, 3])) })
                weightSets.append(weights)
            }
            let targets = try primitive["targets"].array.map { target -> MorphTarget in
                func read(_ key: String) throws -> [SIMD3<Float>] {
                    guard let index = target[key].int else { return [] }
                    let v = try accessor(index).vectors3()
                    guard v.count == count else { throw VRMError.invalid("Morph target count") }; return v
                }
                return MorphTarget(positions: try read("POSITION"), normals: try read("NORMAL"))
            }
            let normalValues = try vectors3("NORMAL")
            if let material = primitive["material"].int { _ = try entry("materials", at: material) }
            return Primitive(material: primitive["material"].int, positions: positions,
                normals: normalValues.isEmpty ? Geometry.makeNormals(positions, triangles: triangles) : normalValues,
                texcoords: texcoords, colors: colors, triangles: triangles, jointSets: jointSets, weightSets: weightSets, targets: targets)
        }
    }

    func skin(_ index: Int) throws -> Skin {
        let json = try entry("skins", at: index), joints = json["joints"].ints
        guard !joints.isEmpty else { throw VRMError.invalid("Empty skin") }
        for node in joints { _ = try entry("nodes", at: node) }
        let matrices: [Matrix4]
        if let index = json["inverseBindMatrices"].int {
            let values = try accessor(index)
            guard values.components == 16, values.count == joints.count else { throw VRMError.invalid("Inverse bind matrix accessor") }
            matrices = (0..<values.count).map { row in Matrix4((0..<16).map { Float(values[row, $0]) }) }
        } else { matrices = Array(repeating: .identity, count: joints.count) }
        return Skin(joints: joints, inverseBind: matrices)
    }
}

public extension Primitive {
    func deform(weights: [Float], matrices: [Matrix4] = [], texCoord: Int = 0) throws -> Geometry {
        var positions = self.positions, normals = self.normals
        for (index, target) in targets.enumerated() where weights.indices.contains(index) && weights[index] != 0 {
            let weight = weights[index]
            for vertex in positions.indices {
                if !target.positions.isEmpty { positions[vertex] += target.positions[vertex] * weight }
                if !target.normals.isEmpty { normals[vertex] += target.normals[vertex] * weight }
            }
        }
        if !matrices.isEmpty, !jointSets.isEmpty {
            let normalMatrices = try matrices.map { try $0.inverted().transposed }
            for vertex in positions.indices {
                var position = SIMD3<Float>.zero, normal = SIMD3<Float>.zero, sum: Float = 0
                for set in jointSets.indices {
                    for lane in 0..<4 {
                        let weight = max(0, weightSets[set][vertex][lane])
                        if weight == 0 { continue }
                        let joint = Int(jointSets[set][vertex][lane])
                        guard matrices.indices.contains(joint) else { throw VRMError.index("skin joint", joint) }
                        position += matrices[joint].point(positions[vertex]) * weight
                        normal += normalMatrices[joint].direction(normals[vertex]) * weight; sum += weight
                    }
                }
                if sum > 0 { positions[vertex] = position / sum; normals[vertex] = normalized(normal) }
            }
        }
        normals = normals.map { normalized($0) }
        let uv = texcoords.indices.contains(texCoord) ? texcoords[texCoord] : Array(repeating: SIMD2<Float>.zero, count: positions.count)
        return Geometry(positions: positions, normals: normals, texcoords: uv, colors: colors, triangles: triangles)
    }
}

public extension Geometry {
    static func makeNormals(_ positions: [SIMD3<Float>], triangles: [UInt32]) -> [SIMD3<Float>] {
        var result = Array(repeating: SIMD3<Float>.zero, count: positions.count)
        for index in stride(from: 0, to: triangles.count - triangles.count % 3, by: 3) {
            let a = Int(triangles[index]), b = Int(triangles[index + 1]), c = Int(triangles[index + 2])
            guard positions.indices.contains(a), positions.indices.contains(b), positions.indices.contains(c) else { continue }
            let n = cross(positions[b] - positions[a], positions[c] - positions[a])
            result[a] += n; result[b] += n; result[c] += n
        }
        return result.map { normalized($0) }
    }
}
