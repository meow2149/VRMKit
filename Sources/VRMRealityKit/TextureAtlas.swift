#if canImport(RealityKit) && !os(visionOS)
import Foundation
import Metal
import RealityKit
import VRMKit

// The matching shader constants live in Toon.metal.
enum MaterialLayout {
    static let stride = 128
    static let textureStart = 12
    static let textureStride = 9
    static let lightStart = 12
    static let lightStride = 8
    static let shadowStride = 19

    static func integer(_ value: Int) -> SIMD4<Float> {
        let bits = UInt32(value)
        return SIMD4(Float(bits & 255), Float((bits >> 8) & 255), Float((bits >> 16) & 255), Float(bits >> 24))
    }
    static func scalar(_ value: Float) -> SIMD4<Float> { integer(Int(value.bitPattern)) }
    static func pair(_ x: Int, _ y: Int) -> SIMD4<Float> { SIMD4(Float(x & 255), Float(x >> 8), Float(y & 255), Float(y >> 8)) }
}

struct AtlasRect { let x: Int; let y: Int; let width: Int; let height: Int }

private struct Shelf {
    let width: Int
    var x = 0
    var y: Int
    var height = 0
    mutating func place(width: Int, height: Int) -> AtlasRect {
        if x + width > self.width { x = 0; y += self.height; self.height = 0 }
        let rect = AtlasRect(x: x, y: y, width: width, height: height)
        x += width; self.height = max(self.height, height); return rect
    }
    var totalHeight: Int { y + height }
}

/// Immutable images, explicit mip levels and original UV data, shared by all material passes.
@MainActor
final class TextureAtlas {
    struct Key: Hashable { let texture: Int; let color: Bool }
    struct Image { let levels: [ImagePixels]; let row: Int }
    let texture: LowLevelTexture
    let resource: TextureResource
    let device: any MTLDevice
    let width: Int
    let height: Int
    let imageRows: [Key: Int]
    let imageLevels: [Key: Int]
    let uvRows: [PrimitiveKey: Int]

    init(document: Document, primitives: [PrimitiveKey: Primitive], options: RenderOptions) throws {
        var rows: [SIMD4<Float>] = [], images: [Image] = [], imageRows: [Key: Int] = [:], imageLevels: [Key: Int] = [:]
        let materials = document.materials
        for material in materials {
            try material.validate(in: document)
            for use in MaterialTexture.allCases {
                guard let slot = material.texture(use) else { continue }
                let key = Key(texture: slot.index, color: use.isColor)
                if imageRows[key] != nil { continue }
                let entry = try document.entry("textures", at: slot.index)
                guard let image = entry["source"].int else { throw VRMError.unsupported("Texture without a standard image source") }
                let pixels = try ImagePixels(data: document.image(image), color: use.isColor, maximumDimension: options.maximumTextureDimension)
                let levels = pixels.mipmaps(color: use.isColor), start = rows.count
                imageRows[key] = start; imageLevels[key] = levels.count
                rows += Array(repeating: .zero, count: levels.count * 2)
                images.append(Image(levels: levels, row: start))
            }
        }
        var uvRows: [PrimitiveKey: Int] = [:]
        for key in primitives.keys.sorted(by: { ($0.mesh, $0.primitive) < ($1.mesh, $1.primitive) }) {
            let primitive = primitives[key]!, start = rows.count, sets = max(1, primitive.texcoords.count)
            guard primitive.triangles.count / 3 <= 16777216 else { throw VRMError.invalid("Primitive triangle table exceeds Float32 indexing") }
            if let index = primitive.material {
                let material = materials[index]
                for use in MaterialTexture.allCases where use != .matcap {
                    if let slot = material.texture(use), !primitive.texcoords.indices.contains(slot.texCoord) {
                        throw VRMError.invalid("Material requires missing TEXCOORD_\(slot.texCoord)")
                    }
                }
            }
            uvRows[key] = start
            rows.append(SIMD4(Float(sets), Float(sets * 6), 0, 0))
            for triangle in stride(from: 0, to: primitive.triangles.count, by: 3) {
                let vertices = (0..<3).map { Int(primitive.triangles[triangle + $0]) }
                for set in 0..<sets {
                    for vertex in vertices {
                        let uv = primitive.texcoords.indices.contains(set) ? primitive.texcoords[set][vertex] : .zero
                        rows.append(MaterialLayout.scalar(uv.x)); rows.append(MaterialLayout.scalar(uv.y))
                    }
                }
            }
        }
        let largest = images.flatMap(\.levels).map(\.width).max() ?? 1
        var width = 512
        while width < largest { width *= 2 }
        width = min(width, options.maximumAtlasDimension)
        guard largest <= width else { throw VRMError.invalid("A texture exceeds maximumAtlasDimension; reduce maximumTextureDimension") }
        var placements: [[AtlasRect]] = [], height = 0
        while true {
            var shelf = Shelf(width: width, y: max(1, (rows.count + width - 1) / width))
            placements = images.map { $0.levels.map { shelf.place(width: $0.width, height: $0.height) } }
            height = shelf.totalHeight
            if height <= options.maximumAtlasDimension { break }
            guard width < options.maximumAtlasDimension else { throw VRMError.invalid("Material atlas exceeds maximumAtlasDimension; reduce maximumTextureDimension") }
            width = min(width * 2, options.maximumAtlasDimension)
        }
        guard width <= options.maximumAtlasDimension else { throw VRMError.invalid("Material atlas width") }
        for (index, image) in images.enumerated() {
            for (level, rect) in placements[index].enumerated() {
                rows[image.row + level * 2] = MaterialLayout.pair(rect.x, rect.y)
                rows[image.row + level * 2 + 1] = MaterialLayout.pair(rect.width, rect.height)
            }
        }
        var descriptor = LowLevelTexture.Descriptor()
        descriptor.textureType = .type2D; descriptor.pixelFormat = .rgba16Float
        descriptor.width = width; descriptor.height = max(1, height); descriptor.mipmapLevelCount = 1; descriptor.textureUsage = [.shaderRead]
        let texture = try LowLevelTexture(descriptor: descriptor), device = texture.read().device
        guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { throw VRMError.invalid("Atlas upload") }
        let destination = texture.replace(using: command)
        let headerHeight = max(1, (rows.count + width - 1) / width)
        rows += Array(repeating: .zero, count: width * headerHeight - rows.count)
        try upload(rows, rect: AtlasRect(x: 0, y: 0, width: width, height: headerHeight), to: destination, device: device, blit: blit)
        for (index, image) in images.enumerated() {
            for (level, pixels) in image.levels.enumerated() { try upload(pixels.pixels, rect: placements[index][level], to: destination, device: device, blit: blit) }
        }
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        self.texture = texture; resource = try TextureResource(from: texture); self.device = device
        self.width = width; self.height = max(1, height)
        self.imageRows = imageRows; self.imageLevels = imageLevels; self.uvRows = uvRows
    }
}

/// Mutable material/light rows and shadow tiles. Static images are never copied during a frame.
@MainActor
final class MaterialBuffer {
    let texture: LowLevelTexture
    let resource: TextureResource
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let width: Int
    let height: Int
    let globalRow: Int
    let shadowRow: Int
    let shadowRects: [AtlasRect]
    let headerHeight: Int
    var rows: [SIMD4<Float>]
    private var initialized = false

    init(materialCount: Int, options: RenderOptions, device expectedDevice: any MTLDevice) throws {
        let global = materialCount * MaterialLayout.stride
        let shadow = global + MaterialLayout.lightStart + options.maximumLights * MaterialLayout.lightStride
        let count = shadow + options.maximumShadowFaces * MaterialLayout.shadowStride
        var width = max(512, options.shadowResolution), headerHeight = 0, height = 0, rects: [AtlasRect] = []
        while true {
            guard width <= options.maximumAtlasDimension else { throw VRMError.invalid("Shadow atlas size; reduce shadowResolution or maximumShadowFaces") }
            headerHeight = max(1, (count + width - 1) / width)
            var shelf = Shelf(width: width, y: headerHeight)
            rects = (0..<options.maximumShadowFaces).map { _ in shelf.place(width: options.shadowResolution, height: options.shadowResolution) }
            height = max(headerHeight, shelf.totalHeight)
            if height <= options.maximumAtlasDimension { break }
            guard width < options.maximumAtlasDimension else { throw VRMError.invalid("Shadow atlas size; reduce shadowResolution or maximumShadowFaces") }
            width = min(width * 2, options.maximumAtlasDimension)
        }
        var descriptor = LowLevelTexture.Descriptor()
        descriptor.textureType = .type2D; descriptor.pixelFormat = .rgba16Float
        descriptor.width = width; descriptor.height = height; descriptor.mipmapLevelCount = 1
        descriptor.textureUsage = [.shaderRead]
        let texture = try LowLevelTexture(descriptor: descriptor), device = texture.read().device
        guard device.registryID == expectedDevice.registryID else { throw VRMError.invalid("Material textures use different Metal devices") }
        self.globalRow = global; self.shadowRow = shadow; self.width = width; self.height = height; self.headerHeight = headerHeight
        self.shadowRects = rects; self.rows = Array(repeating: .zero, count: width * headerHeight)
        self.texture = texture; self.device = device; self.queue = try MaterialQueues.queue(device)
        self.resource = try TextureResource(from: texture)
    }

    func begin(_ command: any MTLCommandBuffer) throws -> any MTLTexture {
        let previous = texture.read(), destination = texture.replace(using: command)
        guard let blit = command.makeBlitCommandEncoder() else { throw VRMError.invalid("Material upload encoder") }
        if initialized, previous !== destination {
            blit.copy(from: previous, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: destination,
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        try upload(rows, rect: AtlasRect(x: 0, y: 0, width: width, height: headerHeight), to: destination, device: device, blit: blit)
        blit.endEncoding(); initialized = true; return destination
    }
}

@MainActor
private enum MaterialQueues {
    static var queues: [UInt64: any MTLCommandQueue] = [:]
    static func queue(_ device: any MTLDevice) throws -> any MTLCommandQueue {
        if let queue = queues[device.registryID] { return queue }
        guard let queue = device.makeCommandQueue() else { throw VRMError.invalid("Material command queue") }
        queues[device.registryID] = queue; return queue
    }
}

@MainActor
private func upload(_ values: [SIMD4<Float>], rect: AtlasRect, to texture: any MTLTexture, device: any MTLDevice, blit: any MTLBlitCommandEncoder) throws {
    let rowBytes = (rect.width * 8 + 255) / 256 * 256, size = rowBytes * rect.height
    guard let buffer = device.makeBuffer(length: size, options: .storageModeShared) else { throw VRMError.invalid("Texture staging allocation") }
    let memory = buffer.contents().bindMemory(to: UInt16.self, capacity: size / 2)
    for y in 0..<rect.height {
        for x in 0..<rect.width {
            let value = values[y * rect.width + x]
            for lane in 0..<4 { memory[y * rowBytes / 2 + x * 4 + lane] = Float16(value[lane]).bitPattern }
        }
    }
    blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: size,
              sourceSize: MTLSize(width: rect.width, height: rect.height, depth: 1), to: texture,
              destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: rect.x, y: rect.y, z: 0))
}
#endif
