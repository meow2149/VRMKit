import Foundation

public enum Bone: String, CaseIterable, Sendable {
    case hips, spine, chest, upperChest, neck, head, leftEye, rightEye, jaw
    case leftUpperLeg, leftLowerLeg, leftFoot, leftToes
    case rightUpperLeg, rightLowerLeg, rightFoot, rightToes
    case leftShoulder, leftUpperArm, leftLowerArm, leftHand
    case rightShoulder, rightUpperArm, rightLowerArm, rightHand
    case leftThumbMetacarpal, leftThumbProximal, leftThumbDistal
    case rightThumbMetacarpal, rightThumbProximal, rightThumbDistal
    case leftIndexProximal, leftIndexIntermediate, leftIndexDistal
    case leftMiddleProximal, leftMiddleIntermediate, leftMiddleDistal
    case leftRingProximal, leftRingIntermediate, leftRingDistal
    case leftLittleProximal, leftLittleIntermediate, leftLittleDistal
    case rightIndexProximal, rightIndexIntermediate, rightIndexDistal
    case rightMiddleProximal, rightMiddleIntermediate, rightMiddleDistal
    case rightRingProximal, rightRingIntermediate, rightRingDistal
    case rightLittleProximal, rightLittleIntermediate, rightLittleDistal


}

public struct Metadata: Sendable {
    public let name: String
    public let authors: [String]
    public let version: String?
    public let contact: String?
    public let license: String?
    /// All permission and license fields remain available in their original form.
    public let raw: JSON
}

public struct MorphBind: Sendable { public let node: Int; public let target: Int; public let weight: Float }
public struct ColorBind: Sendable { public let material: Int; public let property: String; public let value: SIMD4<Float> }
public struct TextureBind: Sendable { public let material: Int; public let scale: SIMD2<Float>; public let offset: SIMD2<Float> }
public enum ExpressionOverride: String, Sendable { case none, block, blend }
public struct Expression: Sendable {
    public let name: String
    public let isBinary: Bool
    public let morphs: [MorphBind]
    public let colors: [ColorBind]
    public let textures: [TextureBind]
    public let overrideBlink: ExpressionOverride
    public let overrideLookAt: ExpressionOverride
    public let overrideMouth: ExpressionOverride
}

public enum ViewMode: String, Sendable { case auto, both, firstPersonOnly, thirdPersonOnly }
public struct LookRange: Sendable {
    public var input: Float
    public var output: Float
    public init(input: Float = 90, output: Float = 10) {
        self.input = input; self.output = output
    }
    func map(_ angle: Float) -> Float {
        clamp(abs(angle) / max(input, 0.0001)) * output
    }
}

public struct LookSettings: Sendable {
    public let usesExpressions: Bool
    public let offset: SIMD3<Float>
    public let inner: LookRange
    public let outer: LookRange
    public let up: LookRange
    public let down: LookRange
}

public struct Collider: Sendable {
    public enum Shape: Sendable {
        case sphere(offset: SIMD3<Float>, radius: Float)
        case capsule(offset: SIMD3<Float>, tail: SIMD3<Float>, radius: Float)
    }
    public let node: Int
    public let shape: Shape
    public init(node: Int, shape: Shape) { self.node = node; self.shape = shape }
}
public struct SpringJoint: Sendable {
    public let node: Int
    public let radius: Float
    public let stiffness: Float
    public let gravity: SIMD3<Float>
    public let drag: Float
    public init(node: Int, radius: Float = 0, stiffness: Float = 1, gravity: SIMD3<Float> = .zero, drag: Float = 0.5) {
        self.node = node; self.radius = radius; self.stiffness = stiffness; self.gravity = gravity; self.drag = drag
    }
}
public struct Spring: Sendable {
    public let name: String?
    public let center: Int?
    public let joints: [SpringJoint]
    public let colliders: [Int]
    public init(name: String? = nil, center: Int? = nil, joints: [SpringJoint], colliders: [Int] = []) {
        self.name = name; self.center = center; self.joints = joints; self.colliders = colliders
    }
}

/// A VRM 1.0 avatar. The source document remains editable.
public struct Avatar: Sendable {
    public let document: Document
    public let specVersion: String
    public let metadata: Metadata
    public let bones: [Bone: Int]
    public let expressions: [String: Expression]
    public let look: LookSettings?
    public let viewModes: [Int: ViewMode]
    public let colliders: [Collider]
    public let springs: [Spring]

    public init(url: URL, resolver: @escaping ResourceResolver = Document.localResource) throws {
        try self.init(document: Document(url: url, resolver: resolver))
    }
    public init(data: Data, baseURL: URL? = nil, resolver: @escaping ResourceResolver = Document.localResource) throws {
        try self.init(document: Document(data: data, baseURL: baseURL, resolver: resolver))
    }
    public init(document: Document) throws {
        self.document = document
        let extensions = document.root["extensions"]
        let raw = extensions["VRMC_vrm"]
        guard !raw.isNull else { throw VRMError.invalid("No VRMC_vrm extension") }
        guard raw["specVersion"].string == "1.0" else { throw VRMError.unsupported("Only VRM 1.0 is supported") }
        specVersion = "1.0"
        let meta = raw["meta"]
        guard let name = meta["name"].string, !name.isEmpty,
              !meta["authors"].array.compactMap(\.string).isEmpty,
              meta["licenseUrl"].string != nil else { throw VRMError.invalid("VRM metadata requires name, authors and licenseUrl") }
        metadata = Metadata(name: name, authors: meta["authors"].array.compactMap(\.string),
                            version: meta["version"].string, contact: meta["contactInformation"].string,
                            license: meta["licenseUrl"].string, raw: meta)
        var rig: [Bone: Int] = [:]
        for (name, value) in raw["humanoid"]["humanBones"].object {
            if let bone = Bone(rawValue: name), let node = value["node"].int { rig[bone] = node }
        }
        let required: [Bone] = [.hips, .spine, .head, .leftUpperLeg, .leftLowerLeg, .leftFoot,
                                .rightUpperLeg, .rightLowerLeg, .rightFoot, .leftUpperArm,
                                .leftLowerArm, .leftHand, .rightUpperArm, .rightLowerArm, .rightHand]
        if let missing = required.first(where: { rig[$0] == nil }) { throw VRMError.invalid("Missing humanoid bone: \(missing.rawValue)") }
        for node in rig.values { _ = try document.entry("nodes", at: node) }
        bones = rig
        expressions = try Self.readExpressions(raw, document: document)
        let lookJSON = raw["lookAt"]
        if !lookJSON.isNull {
            let type = lookJSON["type"].string ?? "bone"
            guard ["bone", "expression"].contains(type) else { throw VRMError.invalid("Look-at type") }
            func range(_ name: String) -> LookRange {
                let value = lookJSON[name]
                return LookRange(input: value["inputMaxValue"].float ?? 90,
                                 output: value["outputScale"].float ?? (type == "expression" ? 1 : 10))
            }
            look = LookSettings(usesExpressions: type == "expression", offset: lookJSON["offsetFromHeadBone"].vector3(),
                                inner: range("rangeMapHorizontalInner"), outer: range("rangeMapHorizontalOuter"),
                                up: range("rangeMapVerticalUp"), down: range("rangeMapVerticalDown"))
        } else { look = nil }
        var modes: [Int: ViewMode] = [:]
        for annotation in raw["firstPerson"]["meshAnnotations"].array {
            guard let node = annotation["node"].int,
                  let mode = ViewMode(rawValue: annotation["type"].string ?? "auto") else { throw VRMError.invalid("First-person annotation") }
            _ = try document.entry("nodes", at: node)
            modes[node] = mode
        }
        viewModes = modes
        let physics = try Self.readSprings(extensions["VRMC_springBone"], document: document)
        colliders = physics.0; springs = physics.1
    }

    public func node(for bone: Bone) -> Int? { bones[bone] }
    public func thumbnail() throws -> Data? {
        guard let image = metadata.raw["thumbnailImage"].int else { return nil }
        return try document.image(image)
    }
    public func makeInstance() throws -> Instance { try Instance(avatar: self) }
}

private extension Avatar {
    static func readExpressions(_ raw: JSON, document: Document) throws -> [String: Expression] {
        var result: [String: Expression] = [:]
        let items = raw["expressions"]["preset"].object.sorted { $0.key < $1.key } + raw["expressions"]["custom"].object.sorted { $0.key < $1.key }
        for (name, item) in items {
            var morphs: [MorphBind] = [], colors: [ColorBind] = [], textures: [TextureBind] = []
            for bind in item["morphTargetBinds"].array {
                guard let target = bind["index"].int, target >= 0, let node = bind["node"].int else { throw VRMError.invalid("Morph target bind") }
                _ = try document.entry("nodes", at: node)
                morphs.append(MorphBind(node: node, target: target, weight: bind["weight"].float ?? 0))
            }
            for bind in item["materialColorBinds"].array {
                guard let material = bind["material"].int, let property = bind["type"].string else { throw VRMError.invalid("Material color bind") }
                _ = try document.entry("materials", at: material)
                colors.append(ColorBind(material: material, property: property, value: bind["targetValue"].vector4()))
            }
            for bind in item["textureTransformBinds"].array {
                guard let material = bind["material"].int else { throw VRMError.invalid("Texture transform bind") }
                _ = try document.entry("materials", at: material)
                let scale = bind["scale"].floats, offset = bind["offset"].floats
                textures.append(TextureBind(material: material, scale: scale.count == 2 ? SIMD2(scale[0], scale[1]) : SIMD2(repeating: 1), offset: offset.count == 2 ? SIMD2(offset[0], offset[1]) : .zero))
            }
            result[name] = Expression(name: name, isBinary: item["isBinary"].bool ?? false, morphs: morphs, colors: colors, textures: textures,
                                      overrideBlink: ExpressionOverride(rawValue: item["overrideBlink"].string ?? "none") ?? .none,
                                      overrideLookAt: ExpressionOverride(rawValue: item["overrideLookAt"].string ?? "none") ?? .none,
                                      overrideMouth: ExpressionOverride(rawValue: item["overrideMouth"].string ?? "none") ?? .none)
        }
        return result
    }

    static func readSprings(_ physics: JSON, document: Document) throws -> ([Collider], [Spring]) {
        if physics.isNull { return ([], []) }
        guard physics["specVersion"].string == "1.0" else { throw VRMError.unsupported("VRMC_springBone specVersion") }
        var colliders: [Collider] = [], springs: [Spring] = []
        for item in physics["colliders"].array {
            guard let node = item["node"].int else { throw VRMError.invalid("Collider node") }
            _ = try document.entry("nodes", at: node)
            let shape = item["shape"]
            guard shape["sphere"].isNull != shape["capsule"].isNull else { throw VRMError.invalid("Collider must have exactly one shape") }
            if !shape["sphere"].isNull {
                let v = shape["sphere"]
                colliders.append(Collider(node: node, shape: .sphere(offset: v["offset"].vector3(), radius: max(0, v["radius"].float ?? 0))))
            } else {
                let v = shape["capsule"]
                colliders.append(Collider(node: node, shape: .capsule(offset: v["offset"].vector3(), tail: v["tail"].vector3(), radius: max(0, v["radius"].float ?? 0))))
            }
            if !item["extensions"].object.isEmpty { throw VRMError.unsupported("Spring collider extensions") }
        }
        let groups = physics["colliderGroups"].array.map { $0["colliders"].ints }
        for spring in physics["springs"].array {
            var joints: [SpringJoint] = []
            for item in spring["joints"].array {
                guard let node = item["node"].int else { throw VRMError.invalid("Spring joint node") }
                _ = try document.entry("nodes", at: node)
                if !item["extensions"].object.isEmpty { throw VRMError.unsupported("Spring joint extensions") }
                joints.append(SpringJoint(node: node, radius: max(0, item["hitRadius"].float ?? 0), stiffness: max(0, item["stiffness"].float ?? 1),
                    gravity: item["gravityDir"].vector3(default: SIMD3(0, -1, 0)) * (item["gravityPower"].float ?? 0), drag: clamp(item["dragForce"].float ?? 0.5)))
            }
            let indices = try spring["colliderGroups"].ints.flatMap { try groups.element(at: $0, kind: "collider group") }
            springs.append(Spring(name: spring["name"].string, center: spring["center"].int, joints: joints, colliders: indices))
        }
        for spring in springs {
            if let center = spring.center { _ = try document.entry("nodes", at: center) }
            for collider in spring.colliders { _ = try colliders.element(at: collider, kind: "collider") }
        }
        return (colliders, springs)
    }
}
