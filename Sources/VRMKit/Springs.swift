import Foundation

final class SpringSolver {
    struct JointState {
        let joint: SpringJoint
        let offset: SIMD3<Float>
        var current: SIMD3<Float>
        var previous: SIMD3<Float>
    }
    struct Chain { let center: Int?; let colliders: [Int]; var joints: [JointState] }
    let colliders: [Collider]
    var chains: [Chain] = []
    var accumulator: Float = 0
    var baseRotations: [Int: Quaternion] = [:]
    var solvedRotations: [Int: Quaternion] = [:]
    let step: Float = 1 / 60

    init(avatar: Avatar, pose: Pose) throws {
        colliders = avatar.colliders
        var occupied: Set<Int> = []
        for spring in avatar.springs {
            let center = spring.center.map { pose.world[$0] } ?? .identity
            let inverse = try center.inverted()
            var states: [JointState] = []
            for (index, joint) in spring.joints.enumerated() {
                guard occupied.insert(joint.node).inserted else { throw VRMError.invalid("A joint belongs to multiple springs") }
                let offset: SIMD3<Float>
                if index + 1 < spring.joints.count {
                    let next = spring.joints[index + 1].node
                    guard pose.isDescendant(next, of: joint.node), next != joint.node else { throw VRMError.invalid("Spring joints must follow the node hierarchy") }
                    offset = try pose.world[joint.node].inverted().point(pose.world[next].translation)
                } else if let child = try avatar.document.entry("nodes", at: joint.node)["children"].ints.first {
                    offset = try pose.world[joint.node].inverted().point(pose.world[child].translation)
                } else { offset = normalized(pose.rest[joint.node].translation) * 0.07 }
                let tail = inverse.point(pose.world[joint.node].point(offset))
                states.append(JointState(joint: joint, offset: offset, current: tail, previous: tail))
            }
            chains.append(Chain(center: spring.center, colliders: spring.colliders, joints: states))
        }
    }

    func restore(pose: inout Pose) throws {
        for (node, base) in baseRotations where pose.local[node].rotation == solvedRotations[node] {
            try pose.setRotation(base, at: node)
        }
        baseRotations.removeAll(keepingCapacity: true); solvedRotations.removeAll(keepingCapacity: true)
    }

    func update(pose: inout Pose, deltaTime: Float, force: SIMD3<Float>) throws {
        accumulator += min(deltaTime, 0.25)
        for chain in chains { for state in chain.joints { baseRotations[state.joint.node] = pose.local[state.joint.node].rotation } }
        var didStep = false
        while accumulator >= step {
            accumulator -= step; didStep = true
            for chainIndex in chains.indices {
                let center = chains[chainIndex].center.map { pose.world[$0] } ?? .identity
                let inverse = try center.inverted()
                for jointIndex in chains[chainIndex].joints.indices {
                    var state = chains[chainIndex].joints[jointIndex]
                    let node = state.joint.node
                    if let base = baseRotations[node] { try pose.setRotation(base, at: node) }
                    let matrix = pose.world[node], origin = matrix.translation
                    let restTail = matrix.point(state.offset), size = length(restTail - origin)
                    if size < 0.000001 { continue }
                    let current = center.point(state.current), previous = center.point(state.previous)
                    var tail = current + (current - previous) * (1 - state.joint.drag)
                    tail += normalized(restTail - origin) * state.joint.stiffness * step
                    tail += (state.joint.gravity + force) * step
                    tail = origin + normalized(tail - origin, fallback: normalized(restTail - origin)) * size
                    for _ in 0..<2 {
                        for colliderIndex in chains[chainIndex].colliders {
                            let collider = colliders[colliderIndex], transform = pose.world[collider.node]
                            let scale = transform.decomposed.scale
                            let multiplier = max(abs(scale.x), max(abs(scale.y), abs(scale.z)))
                            let point: SIMD3<Float>, radius: Float
                            switch collider.shape {
                            case .sphere(let offset, let r): point = transform.point(offset); radius = r * multiplier
                            case .capsule(let offset, let end, let r):
                                let a = transform.point(offset), b = transform.point(end), segment = b - a
                                let t = clamp(dot(tail - a, segment) / max(dot(segment, segment), 0.000001))
                                point = a + segment * t; radius = r * multiplier
                            }
                            let distance = length(tail - point), hit = radius + state.joint.radius
                            if distance < hit {
                                tail = point + normalized(tail - point, fallback: normalized(restTail - origin)) * hit
                                tail = origin + normalized(tail - origin) * size
                            }
                        }
                    }
                    state.previous = state.current; state.current = inverse.point(tail)
                    chains[chainIndex].joints[jointIndex] = state
                    try orient(node: node, offset: state.offset, tail: tail, pose: &pose)
                }
            }
        }
        // Reapply the retained simulation result when the display updates faster than 60 Hz.
        if !didStep {
            for chain in chains {
                let center = chain.center.map { pose.world[$0] } ?? .identity
                for state in chain.joints { try orient(node: state.joint.node, offset: state.offset, tail: center.point(state.current), pose: &pose) }
            }
        }
        for chain in chains { for state in chain.joints { solvedRotations[state.joint.node] = pose.local[state.joint.node].rotation } }
    }

    private func orient(node: Int, offset: SIMD3<Float>, tail: SIMD3<Float>, pose: inout Pose) throws {
        let localDirection = try pose.world[node].inverted().direction(tail - pose.world[node].translation)
        let rotation = pose.local[node].rotation * Quaternion.between(offset, localDirection)
        try pose.setRotation(rotation, at: node)
    }
}
