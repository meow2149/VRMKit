#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

public enum Loader {
    @MainActor
    public static func load(url: URL, scene: Int? = nil, options: RenderOptions = RenderOptions(), resolver: @escaping ResourceResolver = Document.localResource) async throws -> AvatarEntity {
        let document = try await Task.detached { try Document(url: url, resolver: resolver) }.value
        return try load(document: document, scene: scene, options: options)
    }

    @MainActor
    public static func load(data: Data, baseURL: URL? = nil, scene: Int? = nil, options: RenderOptions = RenderOptions()) async throws -> AvatarEntity {
        let document = try await Task.detached { try Document(data: data, baseURL: baseURL) }.value
        return try load(document: document, scene: scene, options: options)
    }

    @MainActor
    public static func load(document: Document, scene: Int? = nil, options: RenderOptions = RenderOptions()) throws -> AvatarEntity {
        guard document.root["extensions"]["VRM"].isNull else { throw VRMError.unsupported("VRM 0.x") }
        let supported: Set<String> = ["VRMC_vrm", "VRMC_springBone", "VRMC_node_constraint", "VRMC_materials_mtoon", "KHR_materials_unlit", "KHR_materials_emissive_strength", "KHR_texture_transform", "KHR_mesh_quantization"]
        for name in document.root["extensionsRequired"].array.compactMap(\.string) where !supported.contains(name) { throw VRMError.unsupported("Required extension \(name)") }
        let avatar = document.root["extensions"]["VRMC_vrm"].isNull ? nil : try Avatar(document: document)
        let instance = try Instance(document: document, avatar: avatar)
        return try AvatarEntity.build(instance: instance, scene: scene, options: options)
    }
}

public struct RenderOptions: Equatable, Sendable {
    public var toonShading: Bool
    public var outlines: Bool
    /// A direction toward the toon light in world space.
    public var lightDirection: SIMD3<Float>
    public var lightColor: SIMD3<Float>
    public var ambientColor: SIMD3<Float>
    public var sceneLighting = true
    public var sceneLightIntensityScale: Float = 0.001
    public var exposure: Float = 1
    public var shadows = true
    public var shadowResolution = 512
    public var maximumShadowFaces = 12
    public var maximumLights = 16
    public var shadowBias: Float = 0.0005
    public var shadowNormalBias: Float = 0.001
    public var shadowStrength: Float = 1
    public var maximumTextureDimension = 16384
    public var maximumAtlasDimension = 16384
    /// Extra local bounds for screen-coordinate outline shells. This never clamps shader width.
    public var outlineBoundsPadding: Float = 1
    public init(toonShading: Bool = true, outlines: Bool = true,
                lightDirection: SIMD3<Float> = SIMD3(0.3, 0.8, 0.5),
                lightColor: SIMD3<Float> = SIMD3(repeating: 1), ambientColor: SIMD3<Float> = SIMD3(repeating: 0.25)) {
        self.toonShading = toonShading; self.outlines = outlines
        self.lightDirection = lightDirection; self.lightColor = lightColor; self.ambientColor = ambientColor
    }

    func validate() throws {
        guard maximumLights > 0, maximumLights <= 64, maximumShadowFaces >= 0, maximumShadowFaces <= 96,
              shadowResolution >= 64, shadowResolution <= 4096,
              maximumTextureDimension > 0, maximumTextureDimension <= 16384,
              maximumAtlasDimension >= 512, maximumAtlasDimension <= 16384,
              [sceneLightIntensityScale, exposure, shadowBias, shadowNormalBias, shadowStrength, outlineBoundsPadding].allSatisfy({ $0.isFinite && $0 >= 0 }),
              shadowStrength <= 1,
              [lightDirection.x, lightDirection.y, lightDirection.z].allSatisfy(\.isFinite),
              [lightColor.x, lightColor.y, lightColor.z, ambientColor.x, ambientColor.y, ambientColor.z]
                .allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw VRMError.invalid("Render options") }
    }

    func hasSameAllocation(as other: RenderOptions) -> Bool {
        maximumTextureDimension == other.maximumTextureDimension && maximumAtlasDimension == other.maximumAtlasDimension &&
        shadowResolution == other.shadowResolution && maximumShadowFaces == other.maximumShadowFaces && maximumLights == other.maximumLights
    }
}
#endif
