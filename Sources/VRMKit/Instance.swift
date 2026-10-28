import Foundation

public struct TextureTransform: Equatable, Sendable {
    public var scale: SIMD2<Float> = SIMD2(repeating: 1)
    public var offset: SIMD2<Float> = .zero
    public init(scale: SIMD2<Float> = SIMD2(repeating: 1), offset: SIMD2<Float> = .zero) { self.scale = scale; self.offset = offset }
}

public enum Gaze: Sendable {
    /// A point in the instance's coordinate space.
    case position(SIMD3<Float>)
    /// Angles in degrees relative to the head's rest orientation.
    case angles(yaw: Float, pitch: Float)
}

/// Mutable avatar state. Use one instance per character, on a single thread.
public final class Instance {
    public let document: Document
    public let avatar: Avatar?
    public var pose: Pose
    public let animations: [Animation]
    public private(set) var materials: [Material]
    public private(set) var morphWeights: [[Float]]
    public private(set) var textureTransforms: [Int: TextureTransform] = [:]
    public private(set) var expressionWeights: [String: Float] = [:]
    public var gaze: Gaze?
    public var springForce: SIMD3<Float> = .zero
    public var springsEnabled = true
    /// Runs after animation, before gaze, constraints and springs.
    public var onPose: ((Instance, Float) throws -> Void)?
    private var baseWeights: [[Float]]
    private var baseMaterials: [Material]
    private var playbacks: [Playback] = []
    private var retargeted: [RetargetPlayback] = []
    private var meshes: [Int: [Primitive]] = [:]
    private var skins: [Int: Skin] = [:]
    private var springSolver: SpringSolver?
    private let constraints: Constraints
    private var eyeBase: [Int: Quaternion] = [:]

    public convenience init(avatar: Avatar) throws { try self.init(document: avatar.document, avatar: avatar) }
    public init(document: Document, avatar: Avatar? = nil) throws {
        self.document = document; self.avatar = avatar
        let initialPose = try Pose(document: document), initialMaterials = document.materials
        pose = initialPose; animations = try document.animations()
        baseMaterials = initialMaterials; materials = initialMaterials
        var weights: [[Float]] = []
        for node in document.entries("nodes") {
            if let mesh = node["mesh"].int {
                let json = try document.entry("meshes", at: mesh)
                let targets = json["primitives"].array.map { $0["targets"].array.count }.max() ?? 0
                let declared = node["weights"].isNull ? json["weights"].floats : node["weights"].floats
                weights.append((0..<targets).map { declared.indices.contains($0) ? declared[$0] : 0 })
            } else { weights.append([]) }
        }
        baseWeights = weights; morphWeights = weights
        constraints = try Constraints(document: document, pose: initialPose)
        if let avatar { springSolver = try SpringSolver(avatar: avatar, pose: pose) }
    }

    @discardableResult
    public func play(_ index: Int, loops: Bool = true) throws -> Playback {
        let playback = Playback(animation: try animations.element(at: index, kind: "animation"), loops: loops)
        playbacks.append(playback); return playback
    }
    @discardableResult
    public func play(_ animation: Animation, loops: Bool = true) throws -> Playback {
        for track in animation.tracks { _ = try pose.local.element(at: track.node, kind: "animation node") }
        let playback = Playback(animation: animation, loops: loops); playbacks.append(playback); return playback
    }
    @discardableResult
    public func play(_ motion: Motion, loops: Bool = true) throws -> RetargetPlayback {
        guard let avatar else { throw VRMError.invalid("VRM motion requires an avatar") }
        let playback = try RetargetPlayback(motion: motion, avatar: avatar, targetPose: pose, loops: loops)
        retargeted.append(playback); return playback
    }
    public func stopAnimations() { playbacks.forEach { $0.stop() }; retargeted.forEach { $0.stop() } }

    public func setExpression(_ name: String, weight: Float) throws {
        guard avatar?.expressions[name] != nil else { throw VRMError.invalid("Unknown expression: \(name)") }
        expressionWeights[name] = weight.isFinite ? clamp(weight) : 0
    }
    public func setExpressions(_ weights: [String: Float]) throws {
        for name in weights.keys where avatar?.expressions[name] == nil { throw VRMError.invalid("Unknown expression: \(name)") }
        for (name, weight) in weights { expressionWeights[name] = weight.isFinite ? clamp(weight) : 0 }
    }
    public func resetExpressions() { expressionWeights.removeAll() }
    public func setMorph(_ weight: Float, target: Int, node: Int) throws {
        guard baseWeights.indices.contains(node) else { throw VRMError.index("node", node) }
        guard baseWeights[node].indices.contains(target) else { throw VRMError.index("morph target", target) }
        baseWeights[node][target] = weight.isFinite ? weight : 0
    }
    public func setMaterialColor(_ color: SIMD4<Float>, property: String = "color", material: Int) throws {
        guard baseMaterials.indices.contains(material) else { throw VRMError.index("material", material) }
        baseMaterials[material].setColor(color, property: property)
    }
    public func resetSprings() throws {
        if let avatar { springSolver = try SpringSolver(avatar: avatar, pose: pose) }
    }

    public func update(deltaTime: Float) throws {
        guard deltaTime.isFinite, deltaTime >= 0 else { throw VRMError.invalid("deltaTime must be finite and nonnegative") }
        for (eye, rotation) in eyeBase { try pose.setRotation(rotation, at: eye) }; eyeBase.removeAll()
        try springSolver?.restore(pose: &pose)
        morphWeights = baseWeights
        playbacks.removeAll { $0.isStopped }; retargeted.removeAll { $0.isStopped }
        for playback in playbacks {
            playback.advance(deltaTime)
            for track in playback.animation.tracks { try apply(track, time: playback.time) }
        }
        pose.rebuild()
        for playback in retargeted { try playback.apply(to: self, deltaTime: deltaTime) }
        try onPose?(self, deltaTime)
        pose.rebuild()
        let gazeWeights = try applyGaze()
        try constraints.apply(to: &pose)
        if springsEnabled { try springSolver?.update(pose: &pose, deltaTime: deltaTime, force: springForce) }
        applyExpressions(gazeWeights)
    }

    private func apply(_ track: AnimationTrack, time: Float) throws {
        let value = track.sample(at: time), node = track.node
        var transform = try pose.local.element(at: node, kind: "animation node")
        switch track.path {
        case .translation: transform.translation = SIMD3(value[0], value[1], value[2])
        case .scale: transform.scale = SIMD3(value[0], value[1], value[2])
        case .rotation: transform.rotation = Quaternion(SIMD4(value[0], value[1], value[2], value[3])).normalized
        case .weights:
            guard value.count == morphWeights[node].count else { throw VRMError.invalid("Animation morph count") }
            morphWeights[node] = value
        }
        pose.apply(transform, at: node)
    }

    private func applyGaze() throws -> [String: Float] {
        guard let avatar, let settings = avatar.look, let gaze, let head = avatar.bones[.head] else { return [:] }
        let yaw: Float, pitch: Float
        switch gaze {
        case .angles(let y, let p): yaw = y; pitch = p
        case .position(let target):
            let headMatrix = pose.world[head]
            let local = try headMatrix.inverted().point(target) - settings.offset
            // VRM 1.0 avatars face positive Z. Positive pitch looks upward.
            yaw = atan2(local.x, local.z) * 180 / .pi
            pitch = atan2(local.y, sqrt(local.x * local.x + local.z * local.z)) * 180 / .pi
        }
        guard yaw.isFinite, pitch.isFinite else { return [:] }
        if settings.usesExpressions {
            return [yaw >= 0 ? "lookLeft" : "lookRight": settings.outer.map(yaw),
                    pitch >= 0 ? "lookUp" : "lookDown": (pitch >= 0 ? settings.up : settings.down).map(pitch)]
        }
        for bone in [Bone.leftEye, .rightEye] {
            guard let eye = avatar.bones[bone] else { continue }
            let base = pose.local[eye].rotation; eyeBase[eye] = base
            let inward = (bone == .leftEye && yaw < 0) || (bone == .rightEye && yaw > 0)
            let y = (inward ? settings.inner : settings.outer).map(yaw) * (yaw < 0 ? -1 : 1) * .pi / 180
            let p = (pitch >= 0 ? settings.up : settings.down).map(pitch) * (pitch < 0 ? -1 : 1) * .pi / 180
            try pose.setRotation(base * Quaternion(angle: y, axis: SIMD3(0, 1, 0)) * Quaternion(angle: -p, axis: SIMD3(1, 0, 0)), at: eye)
        }
        return [:]
    }

    private func applyExpressions(_ gazeWeights: [String: Float]) {
        materials = baseMaterials; textureTransforms.removeAll(keepingCapacity: true)
        guard let expressions = avatar?.expressions else { return }
        var weights = expressionWeights
        for (name, value) in gazeWeights { weights[name] = max(weights[name] ?? 0, clamp(value)) }
        for (name, expression) in expressions where expression.isBinary { weights[name] = (weights[name] ?? 0) > 0.5 ? 1 : 0 }
        var blink: Float = 0, look: Float = 0, mouth: Float = 0
        func suppression(_ mode: ExpressionOverride, _ weight: Float) -> Float {
            switch mode { case .none: 0; case .block: weight > 0 ? 1 : 0; case .blend: weight }
        }
        for (name, expression) in expressions {
            let weight = weights[name] ?? 0
            blink += suppression(expression.overrideBlink, weight); look += suppression(expression.overrideLookAt, weight); mouth += suppression(expression.overrideMouth, weight)
        }
        for name in expressions.keys.sorted() {
            let expression = expressions[name]!
            var weight = weights[name] ?? 0
            if ["blink", "blinkLeft", "blinkRight"].contains(name) { weight *= 1 - clamp(blink) }
            if name.hasPrefix("look") { weight *= 1 - clamp(look) }
            if ["aa", "ih", "ou", "ee", "oh"].contains(name) { weight *= 1 - clamp(mouth) }
            if weight == 0 { continue }
            for bind in expression.morphs where morphWeights.indices.contains(bind.node) && morphWeights[bind.node].indices.contains(bind.target) {
                morphWeights[bind.node][bind.target] += bind.weight * weight
            }
            for bind in expression.colors where materials.indices.contains(bind.material) {
                let base = baseMaterials[bind.material].color(bind.property), current = materials[bind.material].color(bind.property)
                materials[bind.material].setColor(current + (bind.value - base) * weight, property: bind.property)
            }
            for bind in expression.textures {
                guard baseMaterials.indices.contains(bind.material) else { continue }
                let slot = baseMaterials[bind.material].primaryTexture
                let base = TextureTransform(scale: slot?.scale ?? SIMD2(repeating: 1), offset: slot?.offset ?? .zero)
                var transform = textureTransforms[bind.material] ?? base
                transform.scale += (bind.scale - base.scale) * weight; transform.offset += (bind.offset - base.offset) * weight
                textureTransforms[bind.material] = transform
            }
        }
        for node in morphWeights.indices { morphWeights[node] = morphWeights[node].map { clamp($0) } }
    }

    public func primitives(at node: Int) throws -> [Primitive] {
        let json = try document.entry("nodes", at: node)
        guard let mesh = json["mesh"].int else { return [] }
        if let cached = meshes[mesh] { return cached }
        let value = try document.mesh(mesh); meshes[mesh] = value; return value
    }

    public func geometry(node: Int, primitive index: Int, firstPerson: Bool = false) throws -> Geometry {
        let primitive = try primitives(at: node).element(at: index, kind: "primitive")
        let json = try document.entry("nodes", at: node)
        var matrices: [Matrix4] = []
        var skin: Skin?
        if let index = json["skin"].int {
            if skins[index] == nil { skins[index] = try document.skin(index) }; skin = skins[index]
            if let skin {
                let inverse = try pose.world[node].inverted()
                matrices = skin.joints.enumerated().map { inverse * pose.world[$0.element] * skin.inverseBind[$0.offset] }
            }
        }
        let material = primitive.material.flatMap { materials.indices.contains($0) ? materials[$0] : nil }
        let slot = material?.primaryTexture
        var output = try primitive.deform(weights: morphWeights[node], matrices: matrices, texCoord: slot?.texCoord ?? 0)
        if let index = primitive.material, let transform = textureTransforms[index] {
            let rotation = slot?.rotation ?? 0, c = cos(rotation), s = sin(rotation)
            output.texcoords = output.texcoords.map {
                let p = $0 * transform.scale
                return SIMD2(c * p.x - s * p.y, s * p.x + c * p.y) + transform.offset
            }
        } else if let slot { output.texcoords = output.texcoords.map { slot.transform($0) } }
        let mode = avatar?.viewModes[node] ?? .auto
        if (firstPerson && mode == .thirdPersonOnly) || (!firstPerson && mode == .firstPersonOnly) { output.triangles = [] }
        if firstPerson, mode == .auto, let head = avatar?.bones[.head] {
            if skin == nil, pose.isDescendant(node, of: head) { output.triangles = [] }
            else if let skin {
                func hidden(_ vertex: Int) -> Bool {
                    for set in primitive.jointSets.indices {
                        for lane in 0..<4 where primitive.weightSets[set][vertex][lane] > 0 {
                            let joint = Int(primitive.jointSets[set][vertex][lane])
                            if skin.joints.indices.contains(joint), pose.isDescendant(skin.joints[joint], of: head) { return true }
                        }
                    }
                    return false
                }
                output.triangles = stride(from: 0, to: primitive.triangles.count, by: 3).flatMap { start -> [UInt32] in
                    let triangle = Array(primitive.triangles[start..<(start + 3)])
                    return triangle.contains { hidden(Int($0)) } ? [] : triangle
                }
            }
        }
        return output
    }
}
