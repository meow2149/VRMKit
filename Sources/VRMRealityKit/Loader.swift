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
    public init(toonShading: Bool = true, outlines: Bool = true,
                lightDirection: SIMD3<Float> = SIMD3(0.3, 0.8, 0.5),
                lightColor: SIMD3<Float> = SIMD3(repeating: 1), ambientColor: SIMD3<Float> = SIMD3(repeating: 0.25)) {
        self.toonShading = toonShading; self.outlines = outlines
        self.lightDirection = lightDirection; self.lightColor = lightColor; self.ambientColor = ambientColor
    }
}
#endif
