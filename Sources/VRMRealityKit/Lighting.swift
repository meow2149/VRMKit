#if canImport(RealityKit)
import Foundation
import CoreGraphics
import RealityKit
import simd
import VRMKit

public struct ToonLight: Equatable, Sendable {
    public enum Kind: Int, Sendable { case directional, point, spot }
    public var kind: Kind
    /// Linear RGB radiance before attenuation and exposure.
    public var color: SIMD3<Float>
    public var position: SIMD3<Float>
    /// Direction of emitted rays, in world coordinates.
    public var direction: SIMD3<Float>
    public var range: Float
    public var innerAngle: Float
    public var outerAngle: Float
    public var falloff: Float
    public var castsShadow: Bool
    public init(kind: Kind = .directional, color: SIMD3<Float> = SIMD3(repeating: 1), position: SIMD3<Float> = .zero,
                direction: SIMD3<Float> = SIMD3(0, -1, 0), range: Float = 10,
                innerAngle: Float = 20, outerAngle: Float = 35, falloff: Float = 2, castsShadow: Bool = true) {
        self.kind = kind; self.color = color; self.position = position; self.direction = direction
        self.range = range; self.innerAngle = innerAngle; self.outerAngle = outerAngle; self.falloff = falloff; self.castsShadow = castsShadow
    }
}

/// An additional opaque shadow caster. Use world-space transforms for scene props.
public struct ShadowOccluder: Sendable {
    public var geometry: Geometry
    public var transform: Matrix4
    public var doubleSided: Bool
    public init(geometry: Geometry, transform: Matrix4 = .identity, doubleSided: Bool = false) {
        self.geometry = geometry; self.transform = transform; self.doubleSided = doubleSided
    }
}

@MainActor
enum SceneLighting {
    static let query = EntityQuery(where: .has(DirectionalLightComponent.self) || .has(PointLightComponent.self) || .has(SpotLightComponent.self))

    static func lights(in scene: Scene?, scale: Float) -> [ToonLight] {
        guard let scene else { return [] }
        var lights: [ToonLight] = []
        for entity in scene.performQuery(query) where entity.isEnabledInHierarchy {
            let transform = entity.transformMatrix(relativeTo: nil)
            let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let direction = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            if let light = entity.components[DirectionalLightComponent.self] {
                lights.append(ToonLight(color: rgb(light.color.cgColor) * light.intensity * scale, direction: VRMKit.normalized(direction)))
            }
            if let light = entity.components[PointLightComponent.self] {
                lights.append(ToonLight(kind: .point, color: rgb(light.color.cgColor) * light.intensity * scale / (4 * .pi),
                                        position: position, range: light.attenuationRadius, falloff: light.attenuationFalloffExponent))
            }
            if let light = entity.components[SpotLightComponent.self] {
                let outer = light.outerAngleInDegrees * .pi / 180
                let solidAngle = max(0.0001, 2 * Float.pi * (1 - cos(outer)))
                lights.append(ToonLight(kind: .spot, color: rgb(light.color.cgColor) * light.intensity * scale / solidAngle,
                    position: position, direction: VRMKit.normalized(direction), range: light.attenuationRadius,
                    innerAngle: light.innerAngleInDegrees, outerAngle: light.outerAngleInDegrees, falloff: light.attenuationFalloffExponent))
            }
        }
        return lights
    }

    static func rgb(_ color: CGColor) -> SIMD3<Float> {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let converted = color.converted(to: space, intent: .relativeColorimetric, options: nil),
              let components = converted.components, components.count >= 3 else { return SIMD3(repeating: 1) }
        return SIMD3(Float(components[0]), Float(components[1]), Float(components[2]))
    }
}
#endif
