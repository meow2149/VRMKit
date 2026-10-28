import Foundation

public typealias ResourceResolver = @Sendable (URL) throws -> Data

/// glTF JSON and resolved buffers. Copies can be edited independently.
public struct Document: Sendable {
    public var root: JSON
    public internal(set) var buffers: [Data]
    public let baseURL: URL?
    private let resolver: ResourceResolver
    private var extraChunks: [(UInt32, Data)] = []

    public init() {
        root = .object(["asset": .object(["version": .string("2.0"), "generator": .string("VRMKit")])])
        buffers = []; baseURL = nil; resolver = Self.localResource
    }

    public init(url: URL, resolver: @escaping ResourceResolver = Document.localResource) throws {
        try self.init(data: resolver(url), baseURL: url.deletingLastPathComponent(), resolver: resolver)
    }

    public init(data: Data, baseURL: URL? = nil, resolver: @escaping ResourceResolver = Document.localResource) throws {
        self.baseURL = baseURL; self.resolver = resolver
        self.root = .null; self.buffers = []
        let bytes = Data(data)
        var binary: Data?
        if bytes.count >= 4, try bytes.uint32(at: 0) == 0x46546C67 {
            guard bytes.count >= 20, try bytes.uint32(at: 4) == 2,
                  Int(try bytes.uint32(at: 8)) == bytes.count else { throw VRMError.invalid("GLB header") }
            var offset = 12, json: Data?
            while offset < bytes.count {
                guard bytes.count - offset >= 8 else { throw VRMError.invalid("Truncated GLB chunk") }
                let size = Int(try bytes.uint32(at: offset)), type = try bytes.uint32(at: offset + 4)
                guard size % 4 == 0 else { throw VRMError.invalid("Unaligned GLB chunk") }
                let start = try checkedSum(offset, 8), end = try checkedSum(start, size)
                let chunk = try bytes.slice(start..<end)
                if offset == 12, type != 0x4E4F534A { throw VRMError.invalid("JSON must be the first GLB chunk") }
                switch type {
                case 0x4E4F534A:
                    guard json == nil else { throw VRMError.invalid("Multiple JSON chunks") }; json = chunk
                case 0x004E4942:
                    guard binary == nil else { throw VRMError.invalid("Multiple BIN chunks") }; binary = chunk
                default: extraChunks.append((type, chunk))
                }
                offset = end
            }
            guard let json else { throw VRMError.invalid("Missing GLB JSON") }
            root = try JSON.parse(json)
        } else { root = try JSON.parse(bytes) }
        guard case .object = root, root["asset"]["version"].string == "2.0" else { throw VRMError.unsupported("glTF asset version") }
        buffers = []
        for (index, item) in root["buffers"].array.enumerated() {
            guard let count = item["byteLength"].int, count >= 0 else { throw VRMError.invalid("Buffer byteLength") }
            let content: Data
            if let uri = item["uri"].string { content = try Self.resolve(uri, baseURL: baseURL, resolver: resolver) }
            else if index == 0, let binary { content = binary }
            else { throw VRMError.missingResource("Buffer \(index)") }
            guard content.count >= count else { throw VRMError.invalid("Buffer \(index) is shorter than byteLength") }
            buffers.append(Data(content.prefix(count)))
        }
    }

    public static func localResource(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw VRMError.unsupported("Provide a resolver for non-file URLs") }
        return try Data(contentsOf: url)
    }

    static func resolve(_ uri: String, baseURL: URL?, resolver: ResourceResolver) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else { throw VRMError.invalid("Data URI") }
            let header = uri[..<comma], payload = String(uri[uri.index(after: comma)...])
            if header.hasSuffix(";base64"), let decoded = Data(base64Encoded: payload.removingPercentEncoding ?? payload) { return decoded }
            if !header.hasSuffix(";base64"), let decoded = payload.removingPercentEncoding { return Data(decoded.utf8) }
            throw VRMError.invalid("Data URI payload")
        }
        guard let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL,
              url.scheme != nil else { throw VRMError.missingResource(uri) }
        return try resolver(url)
    }

    public func entries(_ key: String) -> [JSON] { root[key].array }
    public func entry(_ key: String, at index: Int) throws -> JSON { try entries(key).element(at: index, kind: key) }
    public var defaultScene: Int? { root["scene"].int ?? (entries("scenes").count == 1 ? 0 : nil) }

    public func bufferView(_ index: Int) throws -> Data {
        let view = try entry("bufferViews", at: index)
        guard let buffer = view["buffer"].int, let count = view["byteLength"].int,
              count >= 0 else { throw VRMError.invalid("Buffer view") }
        let offset = view["byteOffset"].int ?? 0
        guard offset >= 0 else { throw VRMError.invalid("Negative byteOffset") }
        return try buffers.element(at: buffer, kind: "buffer").slice(offset..<checkedSum(offset, count))
    }

    public func image(_ index: Int) throws -> Data {
        let image = try entry("images", at: index)
        if let view = image["bufferView"].int { return try bufferView(view) }
        if let uri = image["uri"].string { return try Self.resolve(uri, baseURL: baseURL, resolver: resolver) }
        throw VRMError.missingResource("Image \(index)")
    }

    /// Embeds external buffers and images into a single portable GLB.
    public func glb() throws -> Data {
        var json = root, binary = Data(), offsets: [Int] = []
        for buffer in buffers { binary.pad(to: 4); offsets.append(binary.count); binary.append(buffer) }
        for (index, view) in entries("bufferViews").enumerated() {
            guard let buffer = view["buffer"].int else { throw VRMError.invalid("Buffer view buffer") }
            let offset = try offsets.element(at: buffer, kind: "buffer")
            json["bufferViews"][index]["buffer"] = .number(0)
            json["bufferViews"][index]["byteOffset"] = .number(Double(try checkedSum(offset, view["byteOffset"].int ?? 0)))
        }
        var views = json["bufferViews"].array
        for (index, image) in entries("images").enumerated() where image["bufferView"].isNull {
            let bytes = try self.image(index)
            binary.pad(to: 4)
            let view = views.count
            views.append(.object(["buffer": .number(0), "byteOffset": .number(Double(binary.count)), "byteLength": .number(Double(bytes.count))]))
            binary.append(bytes)
            var fields = image.object
            fields.removeValue(forKey: "uri")
            fields["bufferView"] = .number(Double(view))
            if fields["mimeType"] == nil { fields["mimeType"] = .string(try Self.imageMIME(bytes)) }
            json["images"][index] = .object(fields)
        }
        if !views.isEmpty { json["bufferViews"] = .array(views) }
        if !binary.isEmpty { json["buffers"] = .array([.object(["byteLength": .number(Double(binary.count))])]) }
        else { var fields = json.object; fields.removeValue(forKey: "buffers"); json = .object(fields) }
        var encoded = try json.data()
        encoded.pad(to: 4, byte: 0x20); binary.pad(to: 4)
        var chunks = Data()
        try chunks.appendChunk(type: 0x4E4F534A, data: encoded)
        if !binary.isEmpty { try chunks.appendChunk(type: 0x004E4942, data: binary) }
        for (type, chunk) in extraChunks { try chunks.appendChunk(type: type, data: chunk) }
        let size = try checkedSum(chunks.count, 12)
        guard size <= Int(UInt32.max) else { throw VRMError.invalid("GLB exceeds 4 GB") }
        var output = Data()
        output.appendUInt32(0x46546C67); output.appendUInt32(2); output.appendUInt32(UInt32(size)); output.append(chunks)
        return output
    }

    public func write(to url: URL) throws { try glb().write(to: url, options: .atomic) }

    @discardableResult
    public mutating func append(_ value: JSON, to key: String) -> Int {
        var array = entries(key); let index = array.count; array.append(value); root[key] = .array(array); return index
    }

    @discardableResult
    public mutating func appendBuffer(_ data: Data, target: Int? = nil) -> Int {
        let buffer = buffers.count
        buffers.append(data)
        append(.object(["byteLength": .number(Double(data.count))]), to: "buffers")
        var view: JSON = .object(["buffer": .number(Double(buffer)), "byteLength": .number(Double(data.count))])
        if let target { view["target"] = .number(Double(target)) }
        return append(view, to: "bufferViews")
    }

    static func imageMIME(_ bytes: Data) throws -> String {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 12, bytes.prefix(4) == Data("RIFF".utf8), bytes[8..<12] == Data("WEBP".utf8) { return "image/webp" }
        throw VRMError.unsupported("Image format; set mimeType explicitly")
    }
}

extension Data {
    func slice(_ range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= count else { throw VRMError.invalid("Byte range outside resource") }
        return Data(self[index(startIndex, offsetBy: range.lowerBound)..<index(startIndex, offsetBy: range.upperBound)])
    }
    func uint32(at offset: Int) throws -> UInt32 {
        let bytes = try slice(offset..<checkedSum(offset, 4))
        return bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16)); append(UInt8(truncatingIfNeeded: value >> 24))
    }
    mutating func pad(to alignment: Int, byte: UInt8 = 0) {
        let count = (alignment - self.count % alignment) % alignment
        append(contentsOf: repeatElement(byte, count: count))
    }
    mutating func appendChunk(type: UInt32, data: Data) throws {
        guard data.count <= Int(UInt32.max) else { throw VRMError.invalid("GLB chunk exceeds 4 GB") }
        appendUInt32(UInt32(data.count)); appendUInt32(type); append(data)
    }
}
