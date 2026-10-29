import Foundation

public struct TextureSampler: Equatable, Hashable, Sendable {
    public enum Wrap: Int, Sendable { case clampToEdge = 33071, mirroredRepeat = 33648, `repeat` = 10497 }
    public enum Filter: Int, Sendable {
        case nearest = 9728, linear = 9729
        case nearestMipmapNearest = 9984, linearMipmapNearest = 9985
        case nearestMipmapLinear = 9986, linearMipmapLinear = 9987
    }
    public var wrapS: Wrap
    public var wrapT: Wrap
    public var minFilter: Filter
    public var magFilter: Filter
    public init(wrapS: Wrap = .repeat, wrapT: Wrap = .repeat, minFilter: Filter = .linear, magFilter: Filter = .linear) {
        self.wrapS = wrapS; self.wrapT = wrapT; self.minFilter = minFilter; self.magFilter = magFilter
    }
    public init(json: JSON) throws {
        guard let s = Wrap(rawValue: json["wrapS"].int ?? 10497), let t = Wrap(rawValue: json["wrapT"].int ?? 10497),
              let min = Filter(rawValue: json["minFilter"].int ?? 9729),
              let mag = Filter(rawValue: json["magFilter"].int ?? 9729), [.nearest, .linear].contains(mag) else { throw VRMError.invalid("glTF sampler") }
        wrapS = s; wrapT = t; minFilter = min; magFilter = mag
    }
}

public extension Document {
    func sampler(for texture: Int) throws -> TextureSampler {
        let entry = try self.entry("textures", at: texture)
        guard let index = entry["sampler"].int else { return TextureSampler() }
        return try TextureSampler(json: self.entry("samplers", at: index))
    }
}
