import Foundation

/// A VRMC_vrm_animation clip with its own humanoid rest skeleton.
public struct Motion: Sendable {
    public let document: Document
    public let animation: Animation
    public let bones: [Bone: Int]
    public let expressions: [String: Int]
    public let lookNode: Int?

    public init(url: URL, resolver: @escaping ResourceResolver = Document.localResource) throws {
        try self.init(document: Document(url: url, resolver: resolver))
    }
    public init(data: Data, baseURL: URL? = nil) throws { try self.init(document: Document(data: data, baseURL: baseURL)) }
    public init(document: Document) throws {
        self.document = document
        let ext = document.root["extensions"]["VRMC_vrm_animation"]
        guard ext["specVersion"].string == "1.0" else { throw VRMError.unsupported("VRMC_vrm_animation specVersion") }
        let clips = try document.animations()
        guard clips.count == 1 else { throw VRMError.invalid("A VRM motion must contain one animation") }
        animation = clips[0]
        var bones: [Bone: Int] = [:], expressions: [String: Int] = [:]
        for (name, value) in ext["humanoid"]["humanBones"].object {
            if let bone = Bone(rawValue: name), let node = value["node"].int { _ = try document.entry("nodes", at: node); bones[bone] = node }
        }
        for category in ["preset", "custom"] {
            for (name, value) in ext["expressions"][category].object {
                if let node = value["node"].int { _ = try document.entry("nodes", at: node); expressions[name] = node }
            }
        }
        self.bones = bones; self.expressions = expressions; lookNode = ext["lookAt"]["node"].int
        if let lookNode { _ = try document.entry("nodes", at: lookNode) }
    }
}

public final class RetargetPlayback {
    public let motion: Motion
    public let playback: Playback
    public var speed: Float { get { playback.speed } set { playback.speed = newValue } }
    public var loops: Bool { get { playback.loops } set { playback.loops = newValue } }
    public var isPaused: Bool { get { playback.isPaused } set { playback.isPaused = newValue } }
    public var isStopped: Bool { playback.isStopped }
    public var time: Float { playback.time }
    private var sourcePose: Pose
    private let sourceRestWorld: [Matrix4]
    private let targetRestWorld: [Matrix4]
    private let mapping: [(Bone, Int, Int)]
    private let translationScale: Float

    init(motion: Motion, avatar: Avatar, targetPose: Pose, loops: Bool) throws {
        self.motion = motion; playback = Playback(animation: motion.animation, loops: loops)
        let initialSource = try Pose(document: motion.document)
        let sourceWorld = initialSource.world
        sourcePose = initialSource; sourceRestWorld = sourceWorld
        var rest = targetPose; rest.reset()
        let targetWorld = rest.world
        targetRestWorld = targetWorld
        func target(_ bone: Bone) -> Int? {
            if let node = avatar.bones[bone] { return node }
            switch bone {
            case .upperChest: return avatar.bones[.chest] ?? avatar.bones[.spine]
            case .chest: return avatar.bones[.spine]
            case .neck: return avatar.bones[.head]
            case .leftShoulder: return avatar.bones[.leftUpperArm]
            case .rightShoulder: return avatar.bones[.rightUpperArm]
            default: return nil
            }
        }
        let indices = Dictionary(uniqueKeysWithValues: initialSource.order.enumerated().map { ($0.element, $0.offset) })
        mapping = motion.bones.compactMap { bone, source in target(bone).map { (bone, source, $0) } }.sorted { indices[$0.1]! < indices[$1.1]! }
        if let sourceHips = motion.bones[.hips], let targetHips = avatar.bones[.hips] {
            let sourceHeight = abs(sourceWorld[sourceHips].translation.y), targetHeight = abs(targetWorld[targetHips].translation.y)
            translationScale = sourceHeight > 0.00001 ? targetHeight / sourceHeight : 1
        } else { translationScale = 1 }
    }

    public func seek(to time: Float) { playback.seek(to: time) }
    public func stop() { playback.stop() }

    func apply(to instance: Instance, deltaTime: Float) throws {
        playback.advance(deltaTime); sourcePose.reset()
        for track in motion.animation.tracks {
            let values = track.sample(at: playback.time)
            var local = sourcePose.local[track.node]
            switch track.path {
            case .rotation: local.rotation = Quaternion(SIMD4(values[0], values[1], values[2], values[3])).normalized
            case .translation: local.translation = SIMD3(values[0], values[1], values[2])
            case .scale: local.scale = SIMD3(values[0], values[1], values[2])
            case .weights: continue
            }
            sourcePose.apply(local, at: track.node)
        }
        sourcePose.rebuild()
        var deltas: [Int: Quaternion] = [:]
        for (_, source, target) in mapping {
            let localDelta = sourcePose.rest[source].rotation.inverse * sourcePose.local[source].rotation
            let restWorld = sourceRestWorld[source].decomposed.rotation
            let delta = restWorld * localDelta * restWorld.inverse
            deltas[target] = (deltas[target] ?? .identity) * delta
        }
        for target in instance.pose.order {
            guard let delta = deltas[target] else { continue }
            let worldRest = targetRestWorld[target].decomposed.rotation
            let rotation = instance.pose.rest[target].rotation * worldRest.inverse * delta * worldRest
            try instance.pose.setRotation(rotation, at: target)
        }
        if let source = motion.bones[.hips], let target = instance.avatar?.bones[.hips] {
            let delta = sourcePose.local[source].translation - sourcePose.rest[source].translation
            let sourceParent = sourcePose.parents[source].map { sourceRestWorld[$0] } ?? .identity
            let targetParent = instance.pose.parents[target].map { targetRestWorld[$0] } ?? .identity
            let movement = try targetParent.inverted().direction(sourceParent.direction(delta)) * translationScale
            var transform = instance.pose.local[target]
            transform.translation = instance.pose.rest[target].translation + movement
            try instance.pose.setTransform(transform, at: target)
        }
        for (name, node) in motion.expressions where instance.avatar?.expressions[name] != nil {
            try instance.setExpression(name, weight: sourcePose.local[node].translation.x)
        }
        if let node = motion.lookNode {
            let direction = sourcePose.local[node].rotation.act(SIMD3(0, 0, 1))
            instance.gaze = .angles(yaw: atan2(direction.x, direction.z) * 180 / .pi,
                                    pitch: atan2(direction.y, sqrt(direction.x * direction.x + direction.z * direction.z)) * 180 / .pi)
        }
    }
}
