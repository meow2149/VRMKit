import Foundation

public struct MergeResult: Sendable {
    public let rootNode: Int
    public let nodes: Range<Int>
    public let materials: Range<Int>
    public let animations: Range<Int>
}

public extension Document {
    /// Appends a plain glTF scene under a new node, preserving all destination indices.
    @discardableResult
    mutating func merge(_ source: Document, parent: Int? = nil, scene: Int? = nil, name: String? = nil) throws -> MergeResult {
        if let parent { _ = try entry("nodes", at: parent) }
        guard let scene = scene ?? source.defaultScene else { throw VRMError.invalid("Choose a source scene") }
        let sourceScene = try source.entry("scenes", at: scene)
        let supported: Set<String> = ["KHR_materials_unlit", "KHR_materials_emissive_strength", "KHR_texture_transform", "KHR_mesh_quantization", "VRMC_materials_mtoon", "VRMC_node_constraint"]
        func check(_ json: JSON) throws {
            switch json {
            case .object(let fields):
                for name in fields["extensions"]?.object.keys ?? Dictionary<String, JSON>().keys where !supported.contains(name) {
                    throw VRMError.unsupported("Merging extension \(name)")
                }
                for value in fields.values { try check(value) }
            case .array(let values): for value in values { try check(value) }
            default: break
            }
        }
        try check(source.root)
        for name in source.root["extensionsRequired"].array.compactMap(\.string) where !supported.contains(name) { throw VRMError.unsupported("Merging required extension \(name)") }
        var copy = self
        let keys = ["buffers", "bufferViews", "accessors", "images", "samplers", "textures", "materials", "meshes", "cameras", "skins", "nodes", "animations"]
        let offsets = Dictionary(uniqueKeysWithValues: keys.map { ($0, copy.entries($0).count) })
        func rebase(_ json: inout JSON, _ field: String, _ key: String) throws {
            if json[field].isNull { return }
            guard let index = json[field].int else { throw VRMError.invalid("Merge index \(field)") }
            _ = try source.entry(key, at: index)
            json[field] = .number(Double(try checkedSum(index, offsets[key]!)))
        }
        func rebaseList(_ json: inout JSON, _ field: String, _ key: String) throws {
            if json[field].isNull { return }
            let values = try json[field].ints.map { index -> Int in _ = try source.entry(key, at: index); return try checkedSum(index, offsets[key]!) }
            json[field] = .integers(values)
        }
        func textures(_ json: inout JSON) throws {
            switch json {
            case .object(var fields):
                for key in fields.keys {
                    var value = fields[key]!
                    if key.lowercased().contains("texture"), value["index"].int != nil { try rebase(&value, "index", "textures") }
                    try textures(&value); fields[key] = value
                }
                json = .object(fields)
            case .array(var values): for index in values.indices { try textures(&values[index]) }; json = .array(values)
            default: break
            }
        }
        for (index, bytes) in source.buffers.enumerated() {
            copy.buffers.append(bytes)
            var buffer = try source.entry("buffers", at: index), fields = buffer.object
            fields.removeValue(forKey: "uri"); buffer = .object(fields); copy.append(buffer, to: "buffers")
        }
        for key in keys where key != "buffers" {
            for original in source.entries(key) {
                var value = original
                switch key {
                case "bufferViews": try rebase(&value, "buffer", "buffers")
                case "accessors":
                    try rebase(&value, "bufferView", "bufferViews")
                    if !value["sparse"].isNull {
                        var indices = value["sparse"]["indices"], values = value["sparse"]["values"]
                        try rebase(&indices, "bufferView", "bufferViews"); try rebase(&values, "bufferView", "bufferViews")
                        value["sparse"]["indices"] = indices; value["sparse"]["values"] = values
                    }
                case "images":
                    if value["bufferView"].int != nil { try rebase(&value, "bufferView", "bufferViews") }
                    else {
                        let index = copy.entries("images").count - offsets["images"]!
                        let bytes = try source.image(index), mime = try value["mimeType"].string ?? Self.imageMIME(bytes)
                        let view = copy.appendBuffer(bytes)
                        var fields = value.object; fields.removeValue(forKey: "uri"); value = .object(fields)
                        value["bufferView"] = .number(Double(view)); value["mimeType"] = .string(mime)
                    }
                case "textures": try rebase(&value, "source", "images"); try rebase(&value, "sampler", "samplers")
                case "materials": try textures(&value)
                case "meshes":
                    for index in value["primitives"].array.indices {
                        var primitive = value["primitives"][index]
                        try rebase(&primitive, "indices", "accessors"); try rebase(&primitive, "material", "materials")
                        var attributes = primitive["attributes"]
                        for key in attributes.object.keys { try rebase(&attributes, key, "accessors") }; primitive["attributes"] = attributes
                        for target in primitive["targets"].array.indices {
                            var fields = primitive["targets"][target]
                            for key in fields.object.keys { try rebase(&fields, key, "accessors") }; primitive["targets"][target] = fields
                        }
                        value["primitives"][index] = primitive
                    }
                case "skins": try rebase(&value, "inverseBindMatrices", "accessors"); try rebase(&value, "skeleton", "nodes"); try rebaseList(&value, "joints", "nodes")
                case "nodes":
                    try rebase(&value, "mesh", "meshes"); try rebase(&value, "skin", "skins"); try rebase(&value, "camera", "cameras"); try rebaseList(&value, "children", "nodes")
                    for kind in ["rotation", "roll", "aim"] {
                        var constraint = value["extensions"]["VRMC_node_constraint"]["constraint"][kind]
                        if !constraint.isNull { try rebase(&constraint, "source", "nodes"); value["extensions"]["VRMC_node_constraint"]["constraint"][kind] = constraint }
                    }
                case "animations":
                    for index in value["samplers"].array.indices {
                        var sampler = value["samplers"][index]; try rebase(&sampler, "input", "accessors"); try rebase(&sampler, "output", "accessors"); value["samplers"][index] = sampler
                    }
                    for index in value["channels"].array.indices {
                        var target = value["channels"][index]["target"]; try rebase(&target, "node", "nodes"); value["channels"][index]["target"] = target
                    }
                default: break
                }
                copy.append(value, to: key)
            }
        }
        for name in source.root["extensionsUsed"].array.compactMap(\.string) { copy.useExtension(name) }
        for name in source.root["extensionsRequired"].array.compactMap(\.string) { copy.useExtension(name, required: true) }
        let node = try copy.addNode(name: name ?? sourceScene["name"].string, parent: parent)
        copy.root["nodes"][node]["children"] = .integers(try sourceScene["nodes"].ints.map { index in _ = try source.entry("nodes", at: index); return index + offsets["nodes"]! })
        let result = MergeResult(rootNode: node, nodes: offsets["nodes"]!..<(offsets["nodes"]! + source.entries("nodes").count),
                                 materials: offsets["materials"]!..<copy.entries("materials").count,
                                 animations: offsets["animations"]!..<copy.entries("animations").count)
        self = copy; return result
    }
}
