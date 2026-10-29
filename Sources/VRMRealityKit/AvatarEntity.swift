#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit

@MainActor
public final class AvatarEntity: Entity {
    public var instance: Instance {
        guard let runtime else { preconditionFailure("Create an avatar with Loader.load") }
        return runtime
    }
    public var isFirstPerson = false
    public var automaticUpdates = true
    public var options = RenderOptions()
    /// Explicit world-space lights. An empty list uses scene lights, then the options light.
    public var lights: [ToonLight] = []
    public var environment: ToonEnvironment?
    public var shadowOccluders: [ShadowOccluder] = []
    /// World-space camera position for transparent sorting, including AR cameras.
    public var cameraPosition: SIMD3<Float>?
    public private(set) var lastError: (any Error)?
    public var onError: ((any Error) -> Void)?
    private var runtime: Instance?
    private var nodes: [Entity] = []
    private var draws: [Draw] = []
    private var factory: MaterialFactory?
    private var allocatedOptions = RenderOptions()
    private var lastNodeTransforms: [Transform] = []
    private var frameLights: [ToonLight] = []
    private let sortGroup = ModelSortGroup(depthPass: nil)

    private struct Draw {
        let node: Int
        let primitive: Int
        let key: PrimitiveKey
        let source: Primitive
        let entity: ModelEntity
        var outline: ModelEntity?
        var geometry: Geometry?
        var shadowGeometry: Geometry?
        var usesToon = false
        var padding = SIMD3<Float>.zero
    }

    public required init() { super.init() }

    static func build(instance: Instance, scene: Int?, options: RenderOptions) throws -> AvatarEntity {
        let entity = AvatarEntity(); entity.runtime = instance; entity.options = options
        entity.name = instance.avatar?.metadata.name ?? "glTF"
        let document = instance.document
        guard let scene = scene ?? document.defaultScene else { throw VRMError.invalid("Choose a scene") }
        let roots = try document.entry("scenes", at: scene)["nodes"].ints
        entity.nodes = document.entries("nodes").enumerated().map { index, value in
            let node = Entity(); node.name = value["name"].string ?? "Node \(index)"; return node
        }
        for node in instance.pose.order {
            if let parent = instance.pose.parents[node] { entity.nodes[parent].addChild(entity.nodes[node]) }
        }
        var visible: Set<Int> = []
        func visit(_ node: Int) throws {
            guard entity.nodes.indices.contains(node) else { throw VRMError.index("scene node", node) }
            if !visible.insert(node).inserted { return }
            for child in document.root["nodes"][node]["children"].ints { try visit(child) }
        }
        for root in roots {
            try visit(root)
            guard instance.pose.parents[root] == nil else { throw VRMError.invalid("Scene roots must have no parent") }
            entity.addChild(entity.nodes[root])
        }
        for node in visible.sorted() {
            guard let mesh = document.root["nodes"][node]["mesh"].int else { continue }
            for (index, primitive) in try instance.primitives(at: node).enumerated() {
                let model = ModelEntity(); model.name = "Primitive \(index)"; entity.nodes[node].addChild(model)
                entity.draws.append(Draw(node: node, primitive: index, key: PrimitiveKey(mesh: mesh, primitive: index), source: primitive, entity: model))
            }
        }
        try entity.update(deltaTime: 0)
        Tick.registerComponent(); AvatarSystem.registerSystem(); entity.components.set(Tick())
        return entity
    }

    public func node(_ index: Int) -> Entity? { nodes.indices.contains(index) ? nodes[index] : nil }
    public func bone(_ bone: Bone) -> Entity? {
        guard let index = instance.avatar?.bones[bone] else { return nil }
        return node(index)
    }
    public func look(at worldPosition: SIMD3<Float>) {
        instance.gaze = .position(convert(position: worldPosition, from: nil))
    }

    /// Loads a linear diffuse environment from an equirectangular image. Rotation is radians about Y.
    public func setEnvironment(data: Data, intensity: Float = 1, rotation: Float = 0) throws {
        let image = try ImagePixels(data: data, color: true, maximumDimension: 512)
        environment = try ToonEnvironment(pixels: image.pixels.map { SIMD3($0.x, $0.y, $0.z) },
            width: image.width, height: image.height, intensity: intensity, rotation: rotation)
    }

    public func update(deltaTime: Float) throws {
        try Self.update([self], deltaTime: deltaTime)
    }

    /// Advances these avatars together before rendering shared shadows. Other scene avatars keep their current poses.
    public static func update(_ avatars: [AvatarEntity], deltaTime: Float) throws {
        guard deltaTime.isFinite, deltaTime >= 0 else { throw VRMError.invalid("deltaTime must be finite and nonnegative") }
        var participants: [AvatarEntity] = [], seen: Set<ObjectIdentifier> = []
        for avatar in avatars {
            if seen.insert(ObjectIdentifier(avatar)).inserted { participants.append(avatar) }
        }
        let advancing = seen
        for avatar in avatars {
            guard let scene = avatar.scene else { continue }
            for case let other as AvatarEntity in scene.performQuery(AvatarSystem.query)
                where other.isEnabledInHierarchy && other.lastError == nil {
                if seen.insert(ObjectIdentifier(other)).inserted { participants.append(other) }
            }
        }
        for avatar in participants { try avatar.prepare(deltaTime: advancing.contains(ObjectIdentifier(avatar)) ? deltaTime : nil) }
        for avatar in participants { try avatar.finish(avatars: Self.peers(of: avatar, in: participants)) }
        for avatar in participants {
            let peers = Self.peers(of: avatar, in: participants)
            if peers.first === avatar { Self.sort(peers, group: avatar.sortGroup) }
        }
    }

    private func material(for draw: Draw) -> VRMKit.Material {
        draw.source.material.flatMap { instance.materials.indices.contains($0) ? instance.materials[$0] : nil }
            ?? VRMKit.Material(json: .object([:]))
    }

    fileprivate func prepare(deltaTime: Float?) throws {
        guard let runtime else { return }
        try options.validate()
        if let cameraPosition, ![cameraPosition.x, cameraPosition.y, cameraPosition.z].allSatisfy(\.isFinite) {
            throw VRMError.invalid("Camera position")
        }
        if let deltaTime {
            // Tracking edits are read back before animation, constraints and springs.
            if lastNodeTransforms.count == nodes.count {
                for index in nodes.indices where nodes[index].transform != lastNodeTransforms[index] {
                    let transform = nodes[index].transform
                    try runtime.pose.setTransform(NodeTransform(translation: transform.translation,
                        rotation: Quaternion(transform.rotation.vector), scale: transform.scale), at: index)
                }
            }
            try runtime.update(deltaTime: deltaTime)
            for index in nodes.indices {
                let local = runtime.pose.local[index]
                nodes[index].transform = Transform(scale: local.scale, rotation: simd_quatf(vector: local.rotation.vector), translation: local.translation)
            }
            lastNodeTransforms = nodes.map(\.transform)
        }
        if factory == nil || !options.hasSameAllocation(as: allocatedOptions) {
            var primitives: [PrimitiveKey: Primitive] = [:]
            for draw in draws { primitives[draw.key] = draw.source }
            factory = try MaterialFactory(document: runtime.document, primitives: primitives, options: options)
            allocatedOptions = options
        }
        guard let factory else { return }
        frameLights = lights
        if frameLights.isEmpty, options.sceneLighting { frameLights = SceneLighting.lights(in: scene, scale: options.sceneLightIntensityScale) }
        if frameLights.isEmpty { frameLights = [ToonLight(color: options.lightColor, direction: -options.lightDirection)] }
        frameLights = Array(frameLights.prefix(options.maximumLights))
        #if !os(visionOS)
        try factory.prepare(materials: runtime.materials, transforms: runtime.textureTransforms, options: options,
            lights: frameLights, environment: environment ?? ToonEnvironment(ambient: options.ambientColor))
        try factory.flushParameters()
        #endif
        for index in draws.indices {
            let draw = draws[index], source = material(for: draw)
            let result = try factory.make(source, index: draw.source.material ?? runtime.materials.count, options: options)
            let geometry = try runtime.geometry(node: draw.node, primitive: draw.primitive, firstPerson: isFirstPerson, applyTextureTransform: !result.usesToon)
            // First-person visibility changes only triangles; hidden heads still cast a complete shadow.
            var shadow = geometry; shadow.triangles = draw.source.triangles
            draws[index].shadowGeometry = shadow
            draw.entity.isEnabled = !geometry.triangles.isEmpty
            if geometry.triangles.isEmpty { draw.outline?.isEnabled = false; continue }
            let padding = outlinePadding(source, draw: draw, enabled: result.outline != nil)
            let changed = draw.geometry.map { $0.positions != geometry.positions || $0.normals != geometry.normals ||
                $0.tangents != geometry.tangents || $0.texcoords != geometry.texcoords || $0.triangles != geometry.triangles } ?? true
            let mesh: MeshResource
            if changed || draw.usesToon != result.usesToon || draw.padding != padding || draw.entity.model == nil {
                mesh = try Self.mesh(geometry, original: draw.source.triangles, toon: result.usesToon, padding: padding)
                draws[index].geometry = geometry; draws[index].usesToon = result.usesToon; draws[index].padding = padding
            } else { mesh = draw.entity.model!.mesh }
            draw.entity.model = ModelComponent(mesh: mesh, materials: [result.surface])
            if let outline = result.outline {
                let model: ModelEntity
                if let existing = draws[index].outline { model = existing }
                else { model = ModelEntity(); model.name = "Outline"; nodes[draw.node].addChild(model); draws[index].outline = model }
                model.isEnabled = true; model.model = ModelComponent(mesh: mesh, materials: [outline])
            } else { draw.outline?.isEnabled = false }
        }
        lastError = nil
    }

    fileprivate func finish(avatars: [AvatarEntity]) throws {
        guard let factory else { return }
        #if !os(visionOS)
        var casters: [ShadowCaster] = []
        for avatar in avatars {
            guard let otherFactory = avatar.factory else { continue }
            for draw in avatar.draws {
                guard avatar.nodes[draw.node].isEnabledInHierarchy, let geometry = draw.shadowGeometry else { continue }
                let source = avatar.material(for: draw)
                // Ordinary transparent surfaces do not write a binary shadow. Depth-writing blend uses a 0.5 cutout.
                if !source.writesDepth { continue }
                casters.append(ShadowCaster(geometry: geometry, transform: Self.matrix(draw.entity.transformMatrix(relativeTo: nil)),
                    doubleSided: source.doubleSided, originalTriangles: draw.source.triangles,
                    source: otherFactory.source(material: draw.source.material ?? avatar.instance.materials.count, key: draw.key,
                        time: source.toon != nil && avatar.options.toonShading ? Float(avatar.instance.elapsedTime) : 0)))
            }
            for occluder in avatar.shadowOccluders {
                casters.append(ShadowCaster(geometry: occluder.geometry, transform: occluder.transform, doubleSided: occluder.doubleSided,
                    originalTriangles: occluder.geometry.triangles, source: nil))
            }
        }
        try factory.renderShadows(lights: frameLights, casters: casters, options: options)
        for draw in draws where draw.entity.isEnabled {
            if var model = draw.entity.model {
                model.materials = try model.materials.map { try factory.bind($0, key: draw.key, time: Float(instance.elapsedTime)) }
                draw.entity.model = model
            }
            if let outline = draw.outline, outline.isEnabled, var model = outline.model {
                model.materials = try model.materials.map { try factory.bind($0, key: draw.key, time: Float(instance.elapsedTime)) }
                outline.model = model
            }
        }
        #endif
        lastError = nil
    }

    private func outlinePadding(_ source: VRMKit.Material, draw: Draw, enabled: Bool) -> SIMD3<Float> {
        guard enabled, let toon = source.toon else { return .zero }
        if toon.outlineMode == "screenCoordinates" { return SIMD3(repeating: options.outlineBoundsPadding) }
        let inverse = simd_inverse(draw.entity.transformMatrix(relativeTo: nil))
        // A world-space sphere maps to these local extents, including nonuniform scale.
        return SIMD3(simd_length(SIMD3(inverse.columns.0.x, inverse.columns.1.x, inverse.columns.2.x)),
                     simd_length(SIMD3(inverse.columns.0.y, inverse.columns.1.y, inverse.columns.2.y)),
                     simd_length(SIMD3(inverse.columns.0.z, inverse.columns.1.z, inverse.columns.2.z))) * toon.outlineWidth
    }

    private static func matrix(_ value: simd_float4x4) -> Matrix4 {
        Matrix4([value.columns.0, value.columns.1, value.columns.2, value.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] })
    }
    fileprivate static func peers(of avatar: AvatarEntity, in avatars: [AvatarEntity]) -> [AvatarEntity] {
        guard let scene = avatar.scene else { return [avatar] }
        return avatars.filter { $0.scene === scene }
    }

    fileprivate static func sort(_ avatars: [AvatarEntity], group: ModelSortGroup) {
        struct Item { let draw: Draw; let queue: Int; let distance: Float; let sequence: Int }
        var camera = avatars.compactMap(\.cameraPosition).first
        if camera == nil, let scene = avatars.first?.scene {
            camera = scene.performQuery(EntityQuery(where: .has(PerspectiveCameraComponent.self)))
                .first(where: { $0.isEnabledInHierarchy }).map { $0.position(relativeTo: nil) }
        }
        var items: [Item] = []
        for avatar in avatars {
            for draw in avatar.draws where draw.entity.isEnabledInHierarchy {
                let source = avatar.material(for: draw)
                let center = draw.geometry.map { geometry -> SIMD3<Float> in
                    guard let first = geometry.positions.first else { return .zero }
                    var minimum = first, maximum = first
                    for point in geometry.positions { minimum = simd_min(minimum, point); maximum = simd_max(maximum, point) }
                    return (minimum + maximum) / 2
                } ?? .zero
                let world = draw.entity.convert(position: center, to: nil)
                let distance = camera.map { simd_length_squared(world - $0) } ?? 0
                items.append(Item(draw: draw, queue: source.renderQueue, distance: distance, sequence: items.count))
            }
        }
        items.sort { a, b in
            if a.queue != b.queue { return a.queue < b.queue }
            if a.queue >= 2500, a.distance != b.distance { return a.distance > b.distance }
            return a.sequence < b.sequence
        }
        for (index, item) in items.enumerated() {
            if let outline = item.draw.outline { outline.components.set(ModelSortGroupComponent(group: group, order: Int32(index * 2))) }
            item.draw.entity.components.set(ModelSortGroupComponent(group: group, order: Int32(index * 2 + 1)))
        }
    }

    private static func mesh(_ geometry: Geometry, original: [UInt32], toon: Bool, padding: SIMD3<Float>) throws -> MeshResource {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], tangents: [SIMD3<Float>] = [], bitangents: [SIMD3<Float>] = []
        var uv0: [SIMD2<Float>] = [], uv1: [SIMD2<Float>] = [], triangles: [UInt32] = []
        if toon {
            #if !os(visionOS)
            let ids = try ShadowRenderer.triangleIDs(geometry.triangles, original: original)
            for (triangle, id) in ids.enumerated() {
                for lane in 0..<3 {
                    let index = Int(geometry.triangles[triangle * 3 + lane]), normal = geometry.normals[index]
                    positions.append(geometry.positions[index]); normals.append(normal)
                    let value = geometry.tangents.isEmpty ? .zero : geometry.tangents[index]
                    let tangent = SIMD3(value.x, value.y, value.z)
                    tangents.append(tangent); bitangents.append(simd_cross(normal, tangent) * value.w)
                    uv0.append(SIMD2(lane == 1 ? 1 : 0, lane == 2 ? 1 : 0)); uv1.append(SIMD2(Float(id), value.w))
                    triangles.append(UInt32(triangles.count))
                }
            }
            #endif
        } else {
            positions = geometry.positions; normals = geometry.normals
            uv0 = geometry.texcoords.map { SIMD2($0.x, 1 - $0.y) }; triangles = geometry.triangles
            for (index, value) in geometry.tangents.enumerated() {
                let tangent = SIMD3(value.x, value.y, value.z)
                tangents.append(tangent); bitangents.append(simd_cross(normals[index], tangent) * value.w)
            }
        }
        guard [padding.x, padding.y, padding.z].allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw VRMError.invalid("Outline bounds require a nonsingular node transform") }
        if padding != .zero, let first = positions.first {
            var minimum = first, maximum = first
            for point in positions { minimum = simd_min(minimum, point); maximum = simd_max(maximum, point) }
            let index = UInt32(positions.count)
            positions += [minimum - padding, maximum + padding]; normals += [SIMD3(0, 1, 0), SIMD3(0, 1, 0)]; uv0 += [.zero, .zero]
            if toon { uv1 += [.zero, .zero] }
            if !tangents.isEmpty { tangents += [.zero, .zero]; bitangents += [.zero, .zero] }
            triangles += [index, index, index, index + 1, index + 1, index + 1]
        }
        var mesh = MeshDescriptor(name: "VRMKit")
        mesh.positions = MeshBuffer(positions); mesh.normals = MeshBuffer(normals); mesh.textureCoordinates = MeshBuffer(uv0)
        if toon { mesh.textureCoordinates1 = MeshBuffer(uv1) }
        if !tangents.isEmpty { mesh.tangents = MeshBuffer(tangents); mesh.bitangents = MeshBuffer(bitangents) }
        mesh.primitives = .triangles(triangles)
        return try MeshResource.generate(from: [mesh])
    }

    fileprivate func failed(_ error: any Error) { lastError = error; automaticUpdates = false; onError?(error) }
}

private struct Tick: Component {}
@MainActor
private struct AvatarSystem: System {
    static let query = EntityQuery(where: .has(Tick.self))
    private let group = ModelSortGroup(depthPass: nil)
    init(scene: Scene) {}
    func update(context: SceneUpdateContext) {
        var ready: [AvatarEntity] = []
        for case let avatar as AvatarEntity in context.entities(matching: Self.query, updatingSystemWhen: .rendering)
            where avatar.isEnabledInHierarchy && (avatar.automaticUpdates || avatar.lastError == nil) {
            do { try avatar.prepare(deltaTime: avatar.automaticUpdates ? Float(context.deltaTime) : nil); ready.append(avatar) }
            catch { avatar.failed(error) }
        }
        for avatar in ready {
            do { try avatar.finish(avatars: ready) }
            catch { avatar.failed(error) }
        }
        AvatarEntity.sort(ready, group: group)
    }
}
#endif
