import Foundation

/// VRMC_materials_mtoon 1.0 parameters. Colors are linear RGB.
public struct ToonSettings: Equatable, Sendable {
    public var shade: SIMD3<Float>
    public var shift: Float
    public var toony: Float
    public var giEqualization: Float
    public var matcap: SIMD3<Float>
    public var rim: SIMD3<Float>
    public var rimPower: Float
    public var rimLift: Float
    public var rimLightingMix: Float
    public var outline: SIMD3<Float>
    public var outlineWidth: Float
    public var outlineMode: String
    public var outlineLightingMix: Float
    public var transparentWithZWrite: Bool
    public var renderQueueOffset: Int
    public var uvScroll: SIMD2<Float>
    public var uvRotation: Float
    public var shadeTexture: TextureSlot?
    public var shiftTexture: TextureSlot?
    public var matcapTexture: TextureSlot?
    public var rimTexture: TextureSlot?
    public var outlineTexture: TextureSlot?
    public var animationMaskTexture: TextureSlot?
    public let raw: JSON

    public init(json: JSON) {
        raw = json
        shade = json["shadeColorFactor"].vector3(default: SIMD3(repeating: 1))
        shift = json["shadingShiftFactor"].float ?? 0
        toony = json["shadingToonyFactor"].float ?? 0.9
        giEqualization = json["giEqualizationFactor"].float ?? 0.9
        matcap = json["matcapFactor"].vector3(default: SIMD3(repeating: 1))
        rim = json["parametricRimColorFactor"].vector3()
        rimPower = json["parametricRimFresnelPowerFactor"].float ?? 5
        rimLift = json["parametricRimLiftFactor"].float ?? 0
        rimLightingMix = json["rimLightingMixFactor"].float ?? 1
        outline = json["outlineColorFactor"].vector3()
        outlineWidth = json["outlineWidthFactor"].float ?? 0
        outlineMode = json["outlineWidthMode"].string ?? "none"
        outlineLightingMix = json["outlineLightingMixFactor"].float ?? 1
        transparentWithZWrite = json["transparentWithZWrite"].bool ?? false
        renderQueueOffset = json["renderQueueOffsetNumber"].int ?? 0
        uvScroll = SIMD2(json["uvAnimationScrollXSpeedFactor"].float ?? 0, json["uvAnimationScrollYSpeedFactor"].float ?? 0)
        uvRotation = json["uvAnimationRotationSpeedFactor"].float ?? 0
        shadeTexture = TextureSlot(json: json["shadeMultiplyTexture"])
        shiftTexture = TextureSlot(json: json["shadingShiftTexture"])
        matcapTexture = TextureSlot(json: json["matcapTexture"])
        rimTexture = TextureSlot(json: json["rimMultiplyTexture"])
        outlineTexture = TextureSlot(json: json["outlineWidthMultiplyTexture"])
        animationMaskTexture = TextureSlot(json: json["uvAnimationMaskTexture"])
    }

    public func validate(alphaMode: Material.AlphaMode) throws {
        guard raw["specVersion"].string == "1.0" else { throw VRMError.unsupported("VRMC_materials_mtoon specVersion") }
        let colors = [shade, matcap, rim, outline].flatMap { [$0.x, $0.y, $0.z] }
        guard colors.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              [toony, giEqualization, rimLightingMix, outlineLightingMix].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              [shift, rimLift, uvScroll.x, uvScroll.y, uvRotation].allSatisfy(\.isFinite),
              rimPower.isFinite, rimPower >= 0, outlineWidth.isFinite, outlineWidth >= 0,
              ["none", "worldCoordinates", "screenCoordinates"].contains(outlineMode) else { throw VRMError.invalid("MToon parameters") }
        let validQueue: ClosedRange<Int> = alphaMode == .blend ? (transparentWithZWrite ? 0...9 : -9...0) : 0...0
        guard validQueue.contains(renderQueueOffset) else { throw VRMError.invalid("MToon render queue offset for alpha mode") }
    }
}

public enum MaterialTexture: Int, CaseIterable, Sendable {
    case base, normal, emission, shade, shift, matcap, rim, outline, animationMask, metallicRoughness, occlusion
    public var isColor: Bool { [.base, .emission, .shade, .matcap, .rim].contains(self) }
}

public extension Material {
    func texture(_ use: MaterialTexture) -> TextureSlot? {
        switch use {
        case .base: baseTexture
        case .normal: normalTexture
        case .emission: emissionTexture
        case .shade: toon?.shadeTexture
        case .shift: toon?.shiftTexture
        case .matcap: toon?.matcapTexture
        case .rim: toon?.rimTexture
        case .outline: toon?.outlineTexture
        case .animationMask: toon?.animationMaskTexture
        case .metallicRoughness: metallicRoughnessTexture
        case .occlusion: occlusionTexture
        }
    }
    var writesDepth: Bool { alphaMode != .blend || toon?.transparentWithZWrite == true }
    var renderQueue: Int {
        switch alphaMode {
        case .opaque: 2000
        case .mask: 2450
        case .blend: (writesDepth ? 2500 : 3000) + (toon?.renderQueueOffset ?? 0)
        }
    }
    func validate(in document: Document) throws {
        guard [baseColor.x, baseColor.y, baseColor.z, baseColor.w].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              [emission.x, emission.y, emission.z].allSatisfy({ $0.isFinite && $0 >= 0 }),
              alphaCutoff.isFinite, alphaCutoff >= 0, alphaCutoff <= 1 else { throw VRMError.invalid("Material color or alpha cutoff") }
        if let toon { try toon.validate(alphaMode: alphaMode) }
        for use in MaterialTexture.allCases {
            guard let slot = texture(use) else { continue }
            _ = try document.entry("textures", at: slot.index)
            _ = try document.sampler(for: slot.index)
            guard slot.texCoord >= 0, [slot.scale.x, slot.scale.y, slot.offset.x, slot.offset.y, slot.rotation, slot.strength].allSatisfy(\.isFinite) else { throw VRMError.invalid("Texture transform") }
            if use == .normal, slot.strength < 0 { throw VRMError.invalid("Normal texture scale") }
            if use == .occlusion, !(0...1).contains(slot.strength) { throw VRMError.invalid("Occlusion texture strength") }
        }
    }
}
