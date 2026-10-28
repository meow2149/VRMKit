import Foundation

public extension Document {
    @discardableResult
    mutating func addScene(name: String? = nil, nodes: [Int] = [], makeDefault: Bool = true) throws -> Int {
        for node in nodes { _ = try entry("nodes", at: node) }
        var scene: JSON = .object(["nodes": .integers(nodes)])
        if let name { scene["name"] = .string(name) }
        let index = append(scene, to: "scenes")
        if makeDefault { root["scene"] = .number(Double(index)) }; return index
    }

    @discardableResult
    mutating func addNode(name: String? = nil, transform: NodeTransform = NodeTransform(), parent: Int? = nil, scene: Int? = nil) throws -> Int {
        if let parent { _ = try entry("nodes", at: parent) }
        if let scene { _ = try entry("scenes", at: scene) }
        var node = transform.json
        if let name { node["name"] = .string(name) }
        let index = append(node, to: "nodes")
        if let parent { root["nodes"][parent]["children"] = .integers(root["nodes"][parent]["children"].ints + [index]) }
        else if let scene = scene ?? defaultScene { root["scenes"][scene]["nodes"] = .integers(root["scenes"][scene]["nodes"].ints + [index]) }
        else { _ = try addScene(nodes: [index]) }
        return index
    }

    mutating func setTransform(_ transform: NodeTransform, node: Int) throws {
        var fields = try entry("nodes", at: node).object
        fields.removeValue(forKey: "matrix")
        fields.merge(transform.json.object) { _, new in new }; root["nodes"][node] = .object(fields)
    }

    mutating func setName(_ name: String, node: Int) throws { _ = try entry("nodes", at: node); root["nodes"][node]["name"] = .string(name) }

    mutating func detachNode(_ node: Int) throws {
        _ = try entry("nodes", at: node)
        for index in entries("nodes").indices { root["nodes"][index]["children"] = .integers(root["nodes"][index]["children"].ints.filter { $0 != node }) }
        for index in entries("scenes").indices { root["scenes"][index]["nodes"] = .integers(root["scenes"][index]["nodes"].ints.filter { $0 != node }) }
    }

    mutating func moveNode(_ node: Int, parent: Int? = nil, scene: Int? = nil) throws {
        let pose = try Pose(document: self)
        _ = try entry("nodes", at: node)
        if let parent {
            _ = try entry("nodes", at: parent)
            guard !pose.isDescendant(parent, of: node) else { throw VRMError.invalid("Moving the node would create a cycle") }
        }
        let scene = scene ?? defaultScene
        if parent == nil { guard let scene else { throw VRMError.invalid("Choose a destination scene") }; _ = try entry("scenes", at: scene) }
        try detachNode(node)
        if let parent { root["nodes"][parent]["children"] = .integers(root["nodes"][parent]["children"].ints + [node]) }
        else if let scene { root["scenes"][scene]["nodes"] = .integers(root["scenes"][scene]["nodes"].ints + [node]) }
    }

    mutating func setAvatarName(_ name: String) throws {
        try requireAvatar(); guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VRMError.invalid("Empty avatar name") }
        root["extensions"]["VRMC_vrm"]["meta"]["name"] = .string(name)
    }
    mutating func setAvatarAuthors(_ authors: [String]) throws {
        try requireAvatar(); guard !authors.isEmpty, authors.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw VRMError.invalid("At least one nonempty author is required") }
        root["extensions"]["VRMC_vrm"]["meta"]["authors"] = .array(authors.map(JSON.string))
    }
    mutating func setAvatarThumbnail(_ image: Data, mimeType: String? = nil) throws {
        try requireAvatar()
        let info = try ImageInfo(data: image)
        guard info.width == info.height else { throw VRMError.invalid("VRM thumbnails must be square") }
        if let mimeType, mimeType != info.mimeType { throw VRMError.invalid("Thumbnail MIME type does not match its data") }
        let mime = info.mimeType
        let view = appendBuffer(image)
        let index = append(.object(["bufferView": .number(Double(view)), "mimeType": .string(mime)]), to: "images")
        root["extensions"]["VRMC_vrm"]["meta"]["thumbnailImage"] = .number(Double(index))
    }

    @discardableResult
    mutating func addFloatAccessor(_ values: [Float], type: String, target: Int? = nil) throws -> Int {
        let components: Int
        switch type { case "SCALAR": components = 1; case "VEC2": components = 2; case "VEC3": components = 3; case "VEC4": components = 4; case "MAT4": components = 16; default: throw VRMError.unsupported("Authoring accessor type \(type)") }
        guard !values.isEmpty, values.count % components == 0, values.allSatisfy(\.isFinite) else { throw VRMError.invalid("Accessor values") }
        var bytes = Data(); for value in values { bytes.appendUInt32(value.bitPattern) }
        let view = appendBuffer(bytes, target: target)
        var accessor: JSON = .object(["bufferView": .number(Double(view)), "componentType": .number(5126), "count": .number(Double(values.count / components)), "type": .string(type)])
        let columns = (0..<components).map { component in stride(from: component, to: values.count, by: components).map { values[$0] } }
        accessor["min"] = .floats(columns.map { $0.min()! }); accessor["max"] = .floats(columns.map { $0.max()! })
        return append(accessor, to: "accessors")
    }

    @discardableResult
    mutating func addMesh(_ geometry: Geometry, material: Int? = nil, name: String? = nil) throws -> Int {
        guard !geometry.positions.isEmpty, !geometry.triangles.isEmpty, geometry.triangles.count % 3 == 0,
              geometry.triangles.allSatisfy({ Int($0) < geometry.positions.count }) else { throw VRMError.invalid("Mesh geometry") }
        if let material { _ = try entry("materials", at: material) }
        for count in [geometry.normals.count, geometry.texcoords.count, geometry.colors.count] where count != 0 && count != geometry.positions.count { throw VRMError.invalid("Vertex attribute count") }
        var copy = self, attributes: JSON = .object([:])
        attributes["POSITION"] = .number(Double(try copy.addFloatAccessor(geometry.positions.flatMap { [$0.x, $0.y, $0.z] }, type: "VEC3", target: 34962)))
        if !geometry.normals.isEmpty { attributes["NORMAL"] = .number(Double(try copy.addFloatAccessor(geometry.normals.flatMap { [$0.x, $0.y, $0.z] }, type: "VEC3", target: 34962))) }
        if !geometry.texcoords.isEmpty { attributes["TEXCOORD_0"] = .number(Double(try copy.addFloatAccessor(geometry.texcoords.flatMap { [$0.x, $0.y] }, type: "VEC2", target: 34962))) }
        if !geometry.colors.isEmpty { attributes["COLOR_0"] = .number(Double(try copy.addFloatAccessor(geometry.colors.flatMap { [$0.x, $0.y, $0.z, $0.w] }, type: "VEC4", target: 34962))) }
        var bytes = Data(); geometry.triangles.forEach { bytes.appendUInt32($0) }
        let view = copy.appendBuffer(bytes, target: 34963)
        let indices = copy.append(.object(["bufferView": .number(Double(view)), "componentType": .number(5125), "count": .number(Double(geometry.triangles.count)), "type": .string("SCALAR")]), to: "accessors")
        var primitive: JSON = .object(["attributes": attributes, "indices": .number(Double(indices))])
        if let material { primitive["material"] = .number(Double(material)) }
        var mesh: JSON = .object(["primitives": .array([primitive])]); if let name { mesh["name"] = .string(name) }
        let index = copy.append(mesh, to: "meshes"); self = copy; return index
    }

    @discardableResult
    mutating func addAnimation(_ animation: Animation) throws -> Int {
        guard !animation.tracks.isEmpty else { throw VRMError.invalid("Empty animation") }
        var copy = self, samplers: [JSON] = [], channels: [JSON] = []
        for track in animation.tracks {
            _ = try copy.entry("nodes", at: track.node)
            let input = try copy.addFloatAccessor(track.times, type: "SCALAR")
            let output = try copy.addFloatAccessor(track.values, type: track.path == .weights ? "SCALAR" : track.path == .rotation ? "VEC4" : "VEC3")
            channels.append(.object(["sampler": .number(Double(samplers.count)), "target": .object(["node": .number(Double(track.node)), "path": .string(track.path.rawValue)])]))
            samplers.append(.object(["input": .number(Double(input)), "output": .number(Double(output)), "interpolation": .string(track.interpolation.rawValue)]))
        }
        var value: JSON = .object(["samplers": .array(samplers), "channels": .array(channels)])
        if let name = animation.name { value["name"] = .string(name) }
        let index = copy.append(value, to: "animations"); self = copy; return index
    }

    mutating func addSpring(_ spring: Spring) throws {
        try requireAvatar()
        let pose = try Pose(document: self)
        guard !spring.joints.isEmpty else { throw VRMError.invalid("Empty spring") }
        if let center = spring.center { _ = try entry("nodes", at: center) }
        let colliders = root["extensions"]["VRMC_springBone"]["colliders"].array
        for collider in spring.colliders { _ = try colliders.element(at: collider, kind: "collider") }
        var joints: [JSON] = []
        for (index, joint) in spring.joints.enumerated() {
            _ = try entry("nodes", at: joint.node)
            guard joint.radius.isFinite, joint.radius >= 0, joint.stiffness.isFinite, joint.stiffness >= 0,
                  joint.drag.isFinite, joint.drag >= 0, joint.drag <= 1,
                  [joint.gravity.x, joint.gravity.y, joint.gravity.z].allSatisfy(\.isFinite) else { throw VRMError.invalid("Spring parameters") }
            if index > 0, joint.node == spring.joints[index - 1].node || !pose.isDescendant(joint.node, of: spring.joints[index - 1].node) { throw VRMError.invalid("Spring joint hierarchy") }
            let power = length(joint.gravity), direction = normalized(joint.gravity, fallback: SIMD3(0, -1, 0))
            joints.append(.object(["node": .number(Double(joint.node)), "hitRadius": .number(Double(joint.radius)), "stiffness": .number(Double(joint.stiffness)),
                                  "dragForce": .number(Double(joint.drag)), "gravityPower": .number(Double(power)), "gravityDir": .floats([direction.x, direction.y, direction.z])]))
        }
        var ext = root["extensions"]["VRMC_springBone"], value: JSON = .object(["joints": .array(joints)])
        ext["specVersion"] = .string("1.0")
        if let name = spring.name { value["name"] = .string(name) }; if let center = spring.center { value["center"] = .number(Double(center)) }
        if !spring.colliders.isEmpty {
            let group = ext["colliderGroups"].array.count
            ext["colliderGroups"] = .array(ext["colliderGroups"].array + [.object(["colliders": .integers(spring.colliders)])])
            value["colliderGroups"] = .integers([group])
        }
        ext["springs"] = .array(ext["springs"].array + [value]); root["extensions"]["VRMC_springBone"] = ext
        useExtension("VRMC_springBone")
    }

    @discardableResult
    mutating func addCollider(_ collider: Collider) throws -> Int {
        try requireAvatar(); _ = try entry("nodes", at: collider.node)
        var ext = root["extensions"]["VRMC_springBone"]
        ext["specVersion"] = .string("1.0")
        let shape: JSON
        func point(_ vector: SIMD3<Float>) throws -> JSON {
            guard [vector.x, vector.y, vector.z].allSatisfy(\.isFinite) else { throw VRMError.invalid("Collider position") }
            return .floats([vector.x, vector.y, vector.z])
        }
        switch collider.shape {
        case .sphere(let offset, let radius):
            guard radius.isFinite, radius >= 0 else { throw VRMError.invalid("Collider radius") }
            shape = .object(["sphere": .object(["offset": try point(offset), "radius": .number(Double(radius))])])
        case .capsule(let offset, let tail, let radius):
            guard radius.isFinite, radius >= 0 else { throw VRMError.invalid("Collider radius") }
            shape = .object(["capsule": .object(["offset": try point(offset), "tail": try point(tail), "radius": .number(Double(radius))])])
        }
        let index = ext["colliders"].array.count
        ext["colliders"] = .array(ext["colliders"].array + [.object(["node": .number(Double(collider.node)), "shape": shape])])
        root["extensions"]["VRMC_springBone"] = ext; useExtension("VRMC_springBone"); return index
    }

    mutating func convertMaterialsToToon(_ indices: [Int]? = nil, toony: Float = 0.9) throws {
        guard toony.isFinite, toony >= 0, toony <= 1 else { throw VRMError.invalid("Toon factor") }
        let indices = indices ?? Array(entries("materials").indices)
        for index in indices { _ = try entry("materials", at: index) }
        for index in indices {
            var material = root["materials"][index]
            if material["extensions"]["VRMC_materials_mtoon"].isNull {
                let base = material["pbrMetallicRoughness"]["baseColorFactor"].vector4()
                material["extensions"]["VRMC_materials_mtoon"] = .object([
                    "specVersion": .string("1.0"), "shadeColorFactor": .floats([base.x * 0.7, base.y * 0.7, base.z * 0.7]),
                    "shadingToonyFactor": .number(Double(toony)), "outlineWidthMode": .string("none")
                ])
                root["materials"][index] = material
            }
        }
        useExtension("VRMC_materials_mtoon")
    }

    /// Copies only humanoid nodes, preserving the rest transforms across omitted ancestors.
    mutating func addMotionSkeleton(from avatar: Avatar) throws -> [Bone: Int] {
        let pose = try Pose(document: avatar.document)
        var copy = self, mapping: [Int: Int] = [:], bones: [Bone: Int] = [:]
        let humanoid = Set(avatar.bones.values)
        for source in pose.order where humanoid.contains(source) {
            var parent = pose.parents[source]
            while let node = parent, !humanoid.contains(node) { parent = pose.parents[node] }
            let matrix = try parent.map { try pose.world[$0].inverted() * pose.world[source] } ?? pose.world[source]
            let target = try copy.addNode(name: avatar.document.root["nodes"][source]["name"].string,
                                          transform: matrix.decomposed, parent: parent.flatMap { mapping[$0] })
            mapping[source] = target
        }
        for (bone, node) in avatar.bones { bones[bone] = mapping[node] }
        try copy.setMotionHumanoid(bones); self = copy; return bones
    }

    mutating func setMotionExpressions(_ nodes: [String: Int], custom: Bool = false) throws {
        var fields: [String: JSON] = [:]
        for (name, node) in nodes { _ = try entry("nodes", at: node); fields[name] = .object(["node": .number(Double(node))]) }
        root["extensions"]["VRMC_vrm_animation"]["specVersion"] = .string("1.0")
        root["extensions"]["VRMC_vrm_animation"]["expressions"][custom ? "custom" : "preset"] = .object(fields)
        useExtension("VRMC_vrm_animation")
    }

    mutating func setMotionLookNode(_ node: Int) throws {
        _ = try entry("nodes", at: node)
        root["extensions"]["VRMC_vrm_animation"]["specVersion"] = .string("1.0")
        root["extensions"]["VRMC_vrm_animation"]["lookAt"]["node"] = .number(Double(node))
        useExtension("VRMC_vrm_animation")
    }

    mutating func setMotionHumanoid(_ bones: [Bone: Int]) throws {
        var entries: [String: JSON] = [:]
        for (bone, node) in bones { _ = try entry("nodes", at: node); entries[bone.rawValue] = .object(["node": .number(Double(node))]) }
        root["extensions"]["VRMC_vrm_animation"]["specVersion"] = .string("1.0")
        root["extensions"]["VRMC_vrm_animation"]["humanoid"]["humanBones"] = .object(entries)
        useExtension("VRMC_vrm_animation")
    }

    mutating func useExtension(_ name: String, required: Bool = false) {
        for key in required ? ["extensionsUsed", "extensionsRequired"] : ["extensionsUsed"] {
            let names = root[key].array.compactMap(\.string)
            if !names.contains(name) { root[key] = .array((names + [name]).map(JSON.string)) }
        }
    }

    private func requireAvatar() throws {
        guard root["extensions"]["VRMC_vrm"]["specVersion"].string == "1.0" else { throw VRMError.invalid("Editing requires a VRM 1.0 document") }
    }
}
