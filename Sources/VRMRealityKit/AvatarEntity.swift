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
    public private(set) var lastError: (any Error)?
    public var onError: ((any Error) -> Void)?
    private var runtime: Instance?
    private var nodes: [Entity] = []
    private var draws: [Draw] = []
    private var factory: MaterialFactory?
    private var lastNodeTransforms: [Transform] = []

    private struct Draw {
        let node: Int
        let primitive: Int
        let material: Int?
        let entity: ModelEntity
        var outline: ModelEntity?
        var geometry: Geometry?
    }

    public required init() { super.init() }

    static func build(instance: Instance, scene: Int?, options: RenderOptions) throws -> AvatarEntity {
        let entity = AvatarEntity(); entity.runtime = instance; entity.options = options
        entity.name = instance.avatar?.metadata.name ?? "glTF"
        let document = instance.document
        guard let scene = scene ?? document.defaultScene else { throw VRMError.invalid("Choose a scene") }
        let roots = try document.entry("scenes", at: scene)["nodes"].ints
        let factory = try MaterialFactory(document: document, options: options); entity.factory = factory
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
            for (index, primitive) in try instance.primitives(at: node).enumerated() {
                let model = ModelEntity(); model.name = "Primitive \(index)"; entity.nodes[node].addChild(model)
                entity.draws.append(Draw(node: node, primitive: index, material: primitive.material, entity: model))
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
        let target = convert(position: worldPosition, from: nil)
        instance.gaze = .position(target)
    }

    public func update(deltaTime: Float) throws {
        guard let runtime, let factory else { return }
        // Entity edits made by tracking code are read back before evaluating animation.
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
        for index in draws.indices {
            let draw = draws[index]
            let geometry = try runtime.geometry(node: draw.node, primitive: draw.primitive, firstPerson: isFirstPerson)
            if geometry.triangles.isEmpty { draw.entity.isEnabled = false; draw.outline?.isEnabled = false; continue }
            draw.entity.isEnabled = true
            let changed = draws[index].geometry.map { $0.positions != geometry.positions || $0.normals != geometry.normals || $0.texcoords != geometry.texcoords || $0.triangles != geometry.triangles } ?? true
            let mesh: MeshResource
            if changed {
                mesh = try Self.mesh(geometry)
                draws[index].geometry = geometry
            } else if let existing = draw.entity.model?.mesh { mesh = existing }
            else { mesh = try Self.mesh(geometry) }
            let material = draw.material.flatMap { runtime.materials.indices.contains($0) ? runtime.materials[$0] : nil } ?? VRMKit.Material(json: .object([:]))
            let result = try factory.make(material, index: draw.material ?? -1, options: options)
            draw.entity.model = ModelComponent(mesh: mesh, materials: [result.surface])
            if let outline = result.outline {
                let model: ModelEntity
                if let existing = draws[index].outline { model = existing }
                else { model = ModelEntity(); model.name = "Outline"; nodes[draw.node].addChild(model); draws[index].outline = model }
                model.isEnabled = true; model.model = ModelComponent(mesh: mesh, materials: [outline])
            } else { draws[index].outline?.isEnabled = false }
        }
        lastError = nil
    }

    private static func mesh(_ geometry: Geometry) throws -> MeshResource {
        var positions = geometry.positions, normals = geometry.normals
        var texcoords = geometry.texcoords.map { SIMD2($0.x, 1 - $0.y) }, triangles = geometry.triangles
        if let first = positions.first {
            var minimum = first, maximum = first
            for point in positions {
                for lane in 0..<3 { minimum[lane] = min(minimum[lane], point[lane]); maximum[lane] = max(maximum[lane], point[lane]) }
            }
            let index = UInt32(positions.count)
            positions += [minimum - SIMD3(repeating: 0.1), maximum + SIMD3(repeating: 0.1)]
            normals += [SIMD3(0, 1, 0), SIMD3(0, 1, 0)]; texcoords += [.zero, .zero]
            triangles += [index, index, index, index + 1, index + 1, index + 1]
        }
        var mesh = MeshDescriptor(name: "VRMKit")
        mesh.positions = MeshBuffer(positions); mesh.normals = MeshBuffer(normals)
        mesh.textureCoordinates = MeshBuffer(texcoords)
        mesh.primitives = .triangles(triangles)
        return try MeshResource.generate(from: [mesh])
    }

    func tick(_ deltaTime: Float) {
        guard automaticUpdates, runtime != nil else { return }
        do { try update(deltaTime: deltaTime) }
        catch { lastError = error; automaticUpdates = false; onError?(error) }
    }
}

private struct Tick: Component {}
private struct AvatarSystem: System {
    static let query = EntityQuery(where: .has(Tick.self))
    init(scene: Scene) {}
    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            (entity as? AvatarEntity)?.tick(Float(context.deltaTime))
        }
    }
}
#endif
