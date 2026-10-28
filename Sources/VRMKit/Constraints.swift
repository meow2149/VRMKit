import Foundation

struct Constraints {
    struct Constraint { let node: Int; let source: Int; let kind: String; let axis: SIMD3<Float>; let weight: Float }
    let items: [Constraint]

    init(document: Document, pose: Pose) throws {
        var constraints: [Int: Constraint] = [:]
        for (node, json) in document.entries("nodes").enumerated() {
            let ext = json["extensions"]["VRMC_node_constraint"]
            if ext.isNull { continue }
            guard ext["specVersion"].string == "1.0" else { throw VRMError.unsupported("VRMC_node_constraint specVersion") }
            let value = ext["constraint"], kinds = ["rotation", "roll", "aim"].filter { !value[$0].isNull }
            guard kinds.count == 1 else { throw VRMError.invalid("Node must have exactly one constraint") }
            let kind = kinds[0], body = value[kind]
            guard let source = body["source"].int, pose.local.indices.contains(source), source != node else { throw VRMError.invalid("Constraint source") }
            let name = body[kind == "aim" ? "aimAxis" : "rollAxis"].string ?? "x"
            let axis: SIMD3<Float>
            switch name {
            case "x", "PositiveX": axis = SIMD3(1, 0, 0)
            case "y", "PositiveY": axis = SIMD3(0, 1, 0)
            case "z", "PositiveZ": axis = SIMD3(0, 0, 1)
            case "NegativeX": axis = SIMD3(-1, 0, 0)
            case "NegativeY": axis = SIMD3(0, -1, 0)
            case "NegativeZ": axis = SIMD3(0, 0, -1)
            default: throw VRMError.invalid("Constraint axis")
            }
            constraints[node] = Constraint(node: node, source: source, kind: kind, axis: axis, weight: clamp(body["weight"].float ?? 1))
        }
        var order: [Constraint] = [], visiting: Set<Int> = [], finished: Set<Int> = []
        func visit(_ node: Int) throws {
            if finished.contains(node) { return }
            guard !visiting.contains(node), let item = constraints[node] else { throw VRMError.invalid("Cyclic constraint dependency") }
            visiting.insert(node)
            var dependencies: Set<Int> = []
            var source: Int? = item.source
            while let index = source { if constraints[index] != nil { dependencies.insert(index) }; source = pose.parents[index] }
            var parent = pose.parents[node]
            while let index = parent { if constraints[index] != nil { dependencies.insert(index) }; parent = pose.parents[index] }
            for dependency in dependencies.sorted() { try visit(dependency) }
            visiting.remove(node); finished.insert(node); order.append(item)
        }
        for node in constraints.keys.sorted() { try visit(node) }
        items = order
    }

    func apply(to pose: inout Pose) throws {
        for item in items {
            let rest = pose.rest[item.node].rotation
            let rotation: Quaternion
            if item.kind == "aim" {
                let worldDirection = pose.world[item.source].translation - pose.world[item.node].translation
                if length(worldDirection) < 0.000001 { continue }
                let parent = pose.parents[item.node].map { pose.world[$0] } ?? .identity
                let direction = rest.inverse.act(try parent.inverted().direction(worldDirection))
                rotation = rest * Quaternion.between(item.axis, direction)
            } else {
                let delta = pose.rest[item.source].rotation.inverse * pose.local[item.source].rotation
                if item.kind == "roll" {
                    let v = delta.vector, projection = item.axis * dot(SIMD3(v.x, v.y, v.z), item.axis)
                    rotation = rest * Quaternion(SIMD4(projection.x, projection.y, projection.z, v.w)).normalized
                } else { rotation = rest * delta }
            }
            try pose.setRotation(Quaternion.slerp(rest, rotation, item.weight), at: item.node)
        }
    }
}
