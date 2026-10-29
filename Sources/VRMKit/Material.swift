import Foundation

public struct TextureSlot: Equatable, Sendable {
    public let index: Int
    public let texCoord: Int
    public let offset: SIMD2<Float>
    public let scale: SIMD2<Float>
    public let rotation: Float
    public let strength: Float
    public init?(json: JSON) {
        guard let index = json["index"].int else { return nil }
        self.index = index
        let transform = json["extensions"]["KHR_texture_transform"]
        texCoord = transform["texCoord"].int ?? json["texCoord"].int ?? 0
        let s = transform["scale"].floats, o = transform["offset"].floats
        scale = s.count == 2 ? SIMD2(s[0], s[1]) : SIMD2(repeating: 1)
        offset = o.count == 2 ? SIMD2(o[0], o[1]) : .zero
        rotation = transform["rotation"].float ?? 0
        strength = json["scale"].float ?? json["strength"].float ?? 1
    }
    public func transform(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        let p = uv * scale, c = cos(rotation), s = sin(rotation)
        return SIMD2(c * p.x - s * p.y, s * p.x + c * p.y) + offset
    }
}

public struct Material: Equatable, Sendable {
    public enum AlphaMode: String, Sendable { case opaque = "OPAQUE", mask = "MASK", blend = "BLEND" }
    public let name: String?
    public var baseColor: SIMD4<Float>
    public var emission: SIMD3<Float>
    public let metallic: Float
    public let roughness: Float
    public let alphaMode: AlphaMode
    public let alphaCutoff: Float
    public let doubleSided: Bool
    public let unlit: Bool
    public let baseTexture: TextureSlot?
    public let normalTexture: TextureSlot?
    public let emissionTexture: TextureSlot?
    public let metallicRoughnessTexture: TextureSlot?
    public let occlusionTexture: TextureSlot?
    public var toon: ToonSettings?
    public let raw: JSON

    public var primaryTexture: TextureSlot? {
        baseTexture ?? normalTexture ?? emissionTexture ?? metallicRoughnessTexture ?? occlusionTexture ?? toon?.shadeTexture
    }

    public init(json: JSON) {
        raw = json; name = json["name"].string
        let pbr = json["pbrMetallicRoughness"]
        baseColor = pbr["baseColorFactor"].vector4()
        emission = json["emissiveFactor"].vector3() * (json["extensions"]["KHR_materials_emissive_strength"]["emissiveStrength"].float ?? 1)
        metallic = clamp(pbr["metallicFactor"].float ?? 1); roughness = clamp(pbr["roughnessFactor"].float ?? 1)
        alphaMode = AlphaMode(rawValue: json["alphaMode"].string ?? "OPAQUE") ?? .opaque
        alphaCutoff = json["alphaCutoff"].float ?? 0.5; doubleSided = json["doubleSided"].bool ?? false
        unlit = !json["extensions"]["KHR_materials_unlit"].isNull
        baseTexture = TextureSlot(json: pbr["baseColorTexture"])
        normalTexture = TextureSlot(json: json["normalTexture"]); emissionTexture = TextureSlot(json: json["emissiveTexture"])
        metallicRoughnessTexture = TextureSlot(json: pbr["metallicRoughnessTexture"]); occlusionTexture = TextureSlot(json: json["occlusionTexture"])
        let mtoon = json["extensions"]["VRMC_materials_mtoon"]
        toon = mtoon.isNull ? nil : ToonSettings(json: mtoon)
    }

    public func color(_ property: String) -> SIMD4<Float> {
        let rgb: SIMD3<Float>
        switch property {
        case "color": return baseColor
        case "emissionColor": rgb = emission
        case "shadeColor": rgb = toon?.shade ?? SIMD3(repeating: 1)
        case "matcapColor": rgb = toon?.matcap ?? SIMD3(repeating: 1)
        case "rimColor": rgb = toon?.rim ?? .zero
        case "outlineColor": rgb = toon?.outline ?? .zero
        default: rgb = .zero
        }
        return SIMD4(rgb.x, rgb.y, rgb.z, 1)
    }

    public mutating func setColor(_ value: SIMD4<Float>, property: String) {
        let rgb = SIMD3(value.x, value.y, value.z)
        switch property {
        case "color": baseColor = value
        case "emissionColor": emission = rgb
        case "shadeColor": toon?.shade = rgb
        case "matcapColor": toon?.matcap = rgb
        case "rimColor": toon?.rim = rgb
        case "outlineColor": toon?.outline = rgb
        default: break
        }
    }
}

public extension Document {
    var materials: [Material] {
        entries("materials").map { Material(json: $0) }
    }
}
