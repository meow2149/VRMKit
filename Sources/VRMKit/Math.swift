import Foundation

public func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
public func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
public func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }
public func normalized(_ v: SIMD3<Float>, fallback: SIMD3<Float> = SIMD3(0, 1, 0)) -> SIMD3<Float> {
    let size = length(v)
    return size > 0.000001 ? v / size : fallback
}
func clamp(_ value: Float, _ low: Float = 0, _ high: Float = 1) -> Float { min(max(value, low), high) }

/// Quaternion components use glTF's x, y, z, w order.
public struct Quaternion: Equatable, Sendable {
    public var vector: SIMD4<Float>
    public static let identity = Quaternion(SIMD4(0, 0, 0, 1))
    public init(_ vector: SIMD4<Float>) { self.vector = vector }
    public init(angle: Float, axis: SIMD3<Float>) {
        let v = normalized(axis) * sin(angle / 2)
        vector = SIMD4(v.x, v.y, v.z, cos(angle / 2))
    }
    public var normalized: Quaternion {
        let v = vector
        let size = sqrt(v.x * v.x + v.y * v.y + v.z * v.z + v.w * v.w)
        return size > 0.000001 ? Quaternion(v / size) : .identity
    }
    public var inverse: Quaternion {
        let q = normalized.vector
        return Quaternion(SIMD4(-q.x, -q.y, -q.z, q.w))
    }
    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        let p = a.vector, q = b.vector
        let x = p.w * q.x + p.x * q.w + p.y * q.z - p.z * q.y
        let y = p.w * q.y - p.x * q.z + p.y * q.w + p.z * q.x
        let z = p.w * q.z + p.x * q.y - p.y * q.x + p.z * q.w
        let w = p.w * q.w - p.x * q.x - p.y * q.y - p.z * q.z
        return Quaternion(SIMD4(x, y, z, w))
    }
    public func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let q = normalized.vector, u = SIMD3(q.x, q.y, q.z)
        return v + 2 * cross(u, cross(u, v) + q.w * v)
    }
    public static func between(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Quaternion {
        let u = VRMKit.normalized(a), v = VRMKit.normalized(b), d = dot(u, v)
        if d < -0.9999 {
            let axis = cross(u, abs(u.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0))
            return Quaternion(angle: .pi, axis: axis)
        }
        let axis = cross(u, v)
        return Quaternion(SIMD4(axis.x, axis.y, axis.z, 1 + d)).normalized
    }
    public static func slerp(_ a: Quaternion, _ b: Quaternion, _ t: Float) -> Quaternion {
        let p = a.normalized.vector
        var q = b.normalized.vector
        var d = p.x * q.x + p.y * q.y + p.z * q.z + p.w * q.w
        if d < 0 { q = -q; d = -d }
        if d > 0.9995 { return Quaternion(p + (q - p) * t).normalized }
        let angle = acos(clamp(d, -1, 1)), divisor = sin(angle)
        return Quaternion((p * sin((1 - t) * angle) + q * sin(t * angle)) / divisor)
    }
}

/// A column-major matrix, independent of Apple's simd module.
public struct Matrix4: Equatable, Sendable {
    public var c0: SIMD4<Float>
    public var c1: SIMD4<Float>
    public var c2: SIMD4<Float>
    public var c3: SIMD4<Float>
    public static let identity = Matrix4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
    public init(_ values: [Float]) {
        precondition(values.count == 16, "A matrix requires 16 components")
        c0 = SIMD4(values[0], values[1], values[2], values[3])
        c1 = SIMD4(values[4], values[5], values[6], values[7])
        c2 = SIMD4(values[8], values[9], values[10], values[11])
        c3 = SIMD4(values[12], values[13], values[14], values[15])
    }
    public init(_ transform: NodeTransform) {
        let q = transform.rotation.normalized.vector, x = q.x, y = q.y, z = q.z, w = q.w
        c0 = SIMD4(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0) * transform.scale.x
        c1 = SIMD4(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0) * transform.scale.y
        c2 = SIMD4(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0) * transform.scale.z
        c3 = SIMD4(transform.translation.x, transform.translation.y, transform.translation.z, 1)
    }
    public func act(_ v: SIMD4<Float>) -> SIMD4<Float> { c0 * v.x + c1 * v.y + c2 * v.z + c3 * v.w }
    public func point(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let r = act(SIMD4(v.x, v.y, v.z, 1)); return SIMD3(r.x, r.y, r.z)
    }
    public func direction(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let r = act(SIMD4(v.x, v.y, v.z, 0)); return SIMD3(r.x, r.y, r.z)
    }
    public var translation: SIMD3<Float> { SIMD3(c3.x, c3.y, c3.z) }
    public static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        var result = Matrix4.identity
        result.c0 = a.act(b.c0); result.c1 = a.act(b.c1)
        result.c2 = a.act(b.c2); result.c3 = a.act(b.c3)
        return result
    }
    public var transposed: Matrix4 {
        Matrix4([c0.x, c1.x, c2.x, c3.x, c0.y, c1.y, c2.y, c3.y,
                 c0.z, c1.z, c2.z, c3.z, c0.w, c1.w, c2.w, c3.w])
    }
    public func inverted() throws -> Matrix4 {
        let columns = [c0, c1, c2, c3]
        var rows = (0..<4).map { row in (0..<8).map { col in col < 4 ? columns[col][row] : (col - 4 == row ? Float(1) : 0) } }
        for pivot in 0..<4 {
            let best = (pivot..<4).max { abs(rows[$0][pivot]) < abs(rows[$1][pivot]) }!
            guard abs(rows[best][pivot]) > 0.0000001 else { throw VRMError.invalid("Singular transform") }
            rows.swapAt(pivot, best)
            let divisor = rows[pivot][pivot]
            for col in 0..<8 { rows[pivot][col] /= divisor }
            for row in 0..<4 where row != pivot {
                let factor = rows[row][pivot]
                for col in 0..<8 { rows[row][col] -= factor * rows[pivot][col] }
            }
        }
        return Matrix4((0..<4).flatMap { col in (0..<4).map { rows[$0][col + 4] } })
    }
    public var decomposed: NodeTransform {
        let a = SIMD3(c0.x, c0.y, c0.z), b = SIMD3(c1.x, c1.y, c1.z), c = SIMD3(c2.x, c2.y, c2.z)
        var scale = SIMD3(length(a), length(b), length(c))
        if dot(cross(a, b), c) < 0 { scale.x = -scale.x }
        let x = a / (abs(scale.x) > 0.000001 ? scale.x : 1)
        let y = b / max(scale.y, 0.000001), z = c / max(scale.z, 0.000001)
        let trace = x.x + y.y + z.z
        let q: SIMD4<Float>
        if trace > 0 {
            let s = sqrt(trace + 1) * 2
            q = SIMD4((y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, s / 4)
        } else if x.x > y.y && x.x > z.z {
            let s = sqrt(max(0, 1 + x.x - y.y - z.z)) * 2
            q = SIMD4(s / 4, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s)
        } else if y.y > z.z {
            let s = sqrt(max(0, 1 + y.y - x.x - z.z)) * 2
            q = SIMD4((y.x + x.y) / s, s / 4, (z.y + y.z) / s, (z.x - x.z) / s)
        } else {
            let s = sqrt(max(0, 1 + z.z - x.x - y.y)) * 2
            q = SIMD4((z.x + x.z) / s, (z.y + y.z) / s, s / 4, (x.y - y.x) / s)
        }
        return NodeTransform(translation: translation, rotation: Quaternion(q).normalized, scale: scale)
    }
}

public struct NodeTransform: Equatable, Sendable {
    public var translation: SIMD3<Float>
    public var rotation: Quaternion
    public var scale: SIMD3<Float>
    public init(translation: SIMD3<Float> = .zero, rotation: Quaternion = .identity, scale: SIMD3<Float> = SIMD3(repeating: 1)) {
        self.translation = translation; self.rotation = rotation; self.scale = scale
    }
    public init(json: JSON) throws {
        if !json["matrix"].isNull {
            let values = json["matrix"].floats
            guard values.count == 16 else { throw VRMError.invalid("Node matrix must have 16 components") }
            self = Matrix4(values).decomposed
        } else {
            translation = json["translation"].vector3()
            rotation = Quaternion(json["rotation"].vector4(default: SIMD4(0, 0, 0, 1))).normalized
            scale = json["scale"].vector3(default: SIMD3(repeating: 1))
        }
    }
    public var json: JSON {
        .object(["translation": .floats([translation.x, translation.y, translation.z]),
                 "rotation": .floats([rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w]),
                 "scale": .floats([scale.x, scale.y, scale.z])])
    }
}
