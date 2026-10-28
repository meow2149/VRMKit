#if canImport(RealityKit)
import Foundation
import CoreGraphics
import ImageIO
import Metal
import RealityKit
import VRMKit
#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#else
import AppKit
private typealias PlatformColor = NSColor
#endif

@MainActor
final class MaterialFactory {
    struct Output { let surface: any RealityKit.Material; let outline: (any RealityKit.Material)? }
    struct Cached { let source: VRMKit.Material; let options: RenderOptions; let output: Output }
    let document: Document
    var textures: [String: TextureResource] = [:]
    var images: [Int: CGImage] = [:]
    var cache: [Int: Cached] = [:]
    #if !os(visionOS)
    var library: (any MTLLibrary)?
    #endif

    init(document: Document, options: RenderOptions) throws {
        self.document = document
        #if !os(visionOS)
        if options.toonShading, document.materials.contains(where: { $0.toon != nil }) {
            guard let device = MTLCreateSystemDefaultDevice(), let url = Bundle.module.url(forResource: "Toon", withExtension: "metal") else { throw VRMError.missingResource("Toon shader") }
            library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        }
        #endif
    }

    func make(_ source: VRMKit.Material, index: Int, options: RenderOptions) throws -> Output {
        if let cached = cache[index], cached.source == source, cached.options == options { return cached.output }
        let slots = [source.baseTexture, source.normalTexture, source.emissionTexture, source.metallicRoughnessTexture, source.occlusionTexture, source.toon?.shadeTexture].compactMap { $0 }
        if let first = slots.first {
            for slot in slots where slot.texCoord != first.texCoord || slot.offset != first.offset || slot.scale != first.scale || slot.rotation != first.rotation {
                throw VRMError.unsupported("Rendering different UV transforms within one material")
            }
        }
        let result: Output
        #if !os(visionOS)
        if options.toonShading, let toon = source.toon {
            if library == nil {
                guard let device = MTLCreateSystemDefaultDevice(), let url = Bundle.module.url(forResource: "Toon", withExtension: "metal") else { throw VRMError.missingResource("Toon shader") }
                library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
            }
            result = try custom(source, toon: toon, options: options)
        } else { result = try standard(source) }
        #else
        result = try standard(source)
        #endif
        cache[index] = Cached(source: source, options: options, output: result); return result
    }

    private func standard(_ source: VRMKit.Material) throws -> Output {
        let base = try texture(source.baseTexture, semantic: .color)
        let tint = color(source.baseColor)
        if source.unlit || source.toon != nil {
            var material = UnlitMaterial()
            material.color = .init(tint: tint, texture: base.map { .init($0) })
            material.faceCulling = source.doubleSided ? .none : .back
            material.blending = source.alphaMode == .blend ? .transparent(opacity: .init(scale: source.baseColor.w)) : .opaque
            material.opacityThreshold = source.alphaMode == .mask ? source.alphaCutoff : nil
            return Output(surface: material, outline: nil)
        }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint, texture: base.map { .init($0) })
        material.metallic = .init(floatLiteral: source.metallic); material.roughness = .init(floatLiteral: source.roughness)
        material.metallic.texture = try texture(source.metallicRoughnessTexture, semantic: .scalar, channel: 2).map { .init($0) }
        material.roughness.texture = try texture(source.metallicRoughnessTexture, semantic: .scalar, channel: 1).map { .init($0) }
        material.normal.texture = try texture(source.normalTexture, semantic: .normal).map { .init($0) }
        material.ambientOcclusion.texture = try texture(source.occlusionTexture, semantic: .scalar, channel: 0).map { .init($0) }
        material.emissiveColor = .init(color: color(SIMD4(source.emission.x, source.emission.y, source.emission.z, 1)), texture: try texture(source.emissionTexture, semantic: .color).map { .init($0) })
        material.faceCulling = source.doubleSided ? .none : .back
        material.blending = source.alphaMode == .blend ? .transparent(opacity: .init(scale: source.baseColor.w)) : .opaque
        material.opacityThreshold = source.alphaMode == .mask ? source.alphaCutoff : nil
        return Output(surface: material, outline: nil)
    }

    func texture(_ slot: TextureSlot?, semantic: TextureResource.Semantic, channel: Int? = nil) throws -> TextureResource? {
        guard let slot else { return nil }
        let key = "\(slot.index):\(semantic):\(channel ?? -1)"
        if let cached = textures[key] { return cached }
        let json = try document.entry("textures", at: slot.index)
        guard let index = json["source"].int else { throw VRMError.unsupported("Texture without a standard image source") }
        let original = try image(index), image: CGImage
        if let channel { image = try extract(channel: channel, from: original) } else { image = original }
        let resource = try TextureResource.generate(from: image, options: .init(semantic: semantic))
        textures[key] = resource; return resource
    }

    private func image(_ index: Int) throws -> CGImage {
        if let image = images[index] { return image }
        let bytes = try document.image(index)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw VRMError.invalid("Image cannot be decoded") }
        images[index] = image; return image
    }

    private func extract(channel: Int, from image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard success else { throw VRMError.invalid("Texture channel conversion") }
        let gray = Data((0..<(width * height)).map { pixel -> UInt8 in
            let alpha = Int(rgba[pixel * 4 + 3]), component = Int(rgba[pixel * 4 + channel])
            return alpha == 0 ? 0 : UInt8(min(255, component * 255 / alpha))
        })
        guard let provider = CGDataProvider(data: gray as CFData), let output = CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw VRMError.invalid("Scalar texture") }
        return output
    }

    private func color(_ value: SIMD4<Float>) -> PlatformColor {
        PlatformColor(red: CGFloat(value.x), green: CGFloat(value.y), blue: CGFloat(value.z), alpha: 1)
    }

    #if !os(visionOS)
    private func custom(_ source: VRMKit.Material, toon: ToonSettings, options: RenderOptions) throws -> Output {
        guard let library else { throw VRMError.missingResource("Toon shader library") }
        let direction = VRMKit.normalized(options.lightDirection)
        let rows: [SIMD4<Float>] = [
            source.baseColor,
            SIMD4(toon.shade.x, toon.shade.y, toon.shade.z, toon.toony),
            SIMD4(direction.x, direction.y, direction.z, toon.shift),
            SIMD4(options.lightColor.x, options.lightColor.y, options.lightColor.z, source.alphaMode == .blend ? 1 : 0),
            SIMD4(options.ambientColor.x, options.ambientColor.y, options.ambientColor.z, toon.rimLift),
            SIMD4(toon.rim.x, toon.rim.y, toon.rim.z, toon.rimPower),
            SIMD4(toon.outline.x, toon.outline.y, toon.outline.z, toon.outlineWidth),
            SIMD4(source.emission.x, source.emission.y, source.emission.z, source.normalTexture?.strength ?? 1),
            SIMD4(source.baseTexture == nil ? 0 : 1, toon.shadeTexture == nil ? 0 : 1, source.emissionTexture == nil ? 0 : 1, source.normalTexture == nil ? 0 : 1)
        ]
        let parameters = try parameterTexture(rows)
        var material = try CustomMaterial(surfaceShader: .init(named: source.alphaMode == .mask ? "avatarToonMask" : "avatarToon", in: library), lightingModel: .unlit)
        material.custom.texture = .init(parameters)
        material.baseColor.texture = try texture(source.baseTexture, semantic: .color).map { .init($0) }
        material.roughness.texture = try texture(toon.shadeTexture, semantic: .color).map { .init($0) }
        material.normal.texture = try texture(source.normalTexture, semantic: .normal).map { .init($0) }
        material.emissiveColor.texture = try texture(source.emissionTexture, semantic: .color).map { .init($0) }
        material.faceCulling = source.doubleSided ? .none : .back
        material.blending = source.alphaMode == .blend ? .transparent(opacity: .init(scale: 1)) : .opaque
        material.opacityThreshold = source.alphaMode == .mask ? source.alphaCutoff : nil
        material.writesDepth = source.alphaMode != .blend || toon.raw["transparentWithZWrite"].bool == true
        var outline: CustomMaterial?
        if options.outlines, toon.outlineWidth > 0, toon.outlineMode != "none" {
            var shell = try CustomMaterial(surfaceShader: .init(named: source.alphaMode == .mask ? "avatarOutlineMask" : "avatarOutline", in: library),
                geometryModifier: .init(named: "avatarExpand", in: library), lightingModel: .unlit)
            shell.custom.texture = .init(parameters); shell.baseColor.texture = material.baseColor.texture
            shell.custom.value.x = toon.outlineMode == "screenCoordinates" ? 1 : 0
            shell.custom.value.y = 0.1
            shell.faceCulling = .front; shell.blending = material.blending; shell.opacityThreshold = material.opacityThreshold
            shell.writesDepth = material.writesDepth; outline = shell
        }
        return Output(surface: material, outline: outline)
    }

    private func parameterTexture(_ rows: [SIMD4<Float>]) throws -> TextureResource {
        let width = rows.count
        var descriptor = LowLevelTexture.Descriptor()
        descriptor.textureType = .type2D; descriptor.pixelFormat = .rgba32Float
        descriptor.width = width; descriptor.height = 1; descriptor.mipmapLevelCount = 1; descriptor.textureUsage = [.shaderRead]
        let texture = try LowLevelTexture(descriptor: descriptor), device = texture.read().device
        guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { throw VRMError.invalid("Toon parameter upload") }
        let dataSize = width * MemoryLayout<SIMD4<Float>>.stride
        let bytesPerRow = (dataSize + 255) / 256 * 256
        guard let buffer = device.makeBuffer(length: bytesPerRow, options: .storageModeShared) else { throw VRMError.invalid("Toon parameter allocation") }
        rows.withUnsafeBufferPointer { data in buffer.contents().copyMemory(from: data.baseAddress!, byteCount: dataSize) }
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow,
                  sourceSize: MTLSize(width: width, height: 1, depth: 1), to: texture.replace(using: command),
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        if command.status == .error {
            if let error = command.error { throw error }
            throw VRMError.invalid("Toon parameter upload")
        }
        return try TextureResource(from: texture)
    }
    #endif
}
#endif
