import Foundation

/// Local transforms and their derived world matrices, in document node order.
public struct Pose: Sendable {
    public private(set) var local: [NodeTransform]
    public private(set) var world: [Matrix4]
    public let parents: [Int?]
    public let order: [Int]
    public let rest: [NodeTransform]

    public init(document: Document) throws {
        let nodes = document.entries("nodes")
        local = try nodes.map { try NodeTransform(json: $0) }; rest = local
        var parents = Array<Int?>(repeating: nil, count: nodes.count)
        for (node, value) in nodes.enumerated() {
            for child in value["children"].ints {
                guard nodes.indices.contains(child) else { throw VRMError.index("node", child) }
                guard child != node, parents[child] == nil else { throw VRMError.invalid("A node must have exactly one parent") }
                parents[child] = node
            }
        }
        var order: [Int] = [], states = Array(repeating: 0, count: nodes.count)
        func visit(_ node: Int) throws {
            if states[node] == 2 { return }
            guard states[node] == 0 else { throw VRMError.invalid("Cyclic node graph") }
            states[node] = 1
            if let parent = parents[node] { try visit(parent) }
            states[node] = 2; order.append(node)
        }
        for node in nodes.indices { try visit(node) }
        self.parents = parents; self.order = order
        world = Array(repeating: .identity, count: nodes.count)
        rebuild()
    }

    public mutating func setTransform(_ transform: NodeTransform, at node: Int) throws {
        guard local.indices.contains(node) else { throw VRMError.index("node", node) }
        let values = [transform.translation.x, transform.translation.y, transform.translation.z,
                      transform.rotation.vector.x, transform.rotation.vector.y, transform.rotation.vector.z, transform.rotation.vector.w,
                      transform.scale.x, transform.scale.y, transform.scale.z]
        guard values.allSatisfy(\.isFinite) else { throw VRMError.invalid("Non-finite node transform") }
        local[node] = transform; rebuild()
    }
    public mutating func setRotation(_ rotation: Quaternion, at node: Int) throws {
        var transform = try local.element(at: node, kind: "node")
        transform.rotation = rotation.normalized; try setTransform(transform, at: node)
    }
    public mutating func reset() { local = rest; rebuild() }
    public func isDescendant(_ node: Int, of ancestor: Int) -> Bool {
        guard parents.indices.contains(node) else { return false }
        var cursor: Int? = node
        while let current = cursor { if current == ancestor { return true }; cursor = parents[current] }
        return false
    }
    public mutating func rebuild() {
        for node in order {
            let matrix = Matrix4(local[node])
            world[node] = parents[node].map { world[$0] * matrix } ?? matrix
        }
    }
    mutating func apply(_ transform: NodeTransform, at node: Int) { local[node] = transform }
}
