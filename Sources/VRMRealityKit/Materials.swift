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

struct PrimitiveKey: Hashable { let mesh: Int; let primitive: Int }

@MainActor
final class MaterialFactory {
    struct Output { let surface: any RealityKit.Material; let outline: (any RealityKit.Material)?; let usesToon: Bool }
    struct Cached { let source: VRMKit.Material; let options: RenderOptions; let output: Output }
    let document: Document
    let materialCount: Int
    let maximumTextureDimension: Int
    var textures: [String: TextureResource] = [:]
    var cache: [Int: Cached] = [:]
    #if !os(visionOS)
    let atlas: TextureAtlas
    let buffer: MaterialBuffer
    let library: any MTLLibrary
    let shadows: ShadowRenderer
    #endif

    init(document: Document, primitives: [PrimitiveKey: Primitive], options: RenderOptions) throws {
        try options.validate()
        self.document = document
        materialCount = document.materials.count; maximumTextureDimension = options.maximumTextureDimension
        #if !os(visionOS)
        let atlas = try TextureAtlas(document: document, primitives: primitives, options: options)
        let buffer = try MaterialBuffer(materialCount: document.materials.count + 1, options: options, device: atlas.device)
        guard let url = Bundle.module.url(forResource: "Toon", withExtension: "metal") else { throw VRMError.missingResource("Toon shader") }
        let library = try atlas.device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        self.atlas = atlas; self.buffer = buffer; self.library = library
        shadows = try ShadowRenderer(device: atlas.device, library: library, resolution: options.shadowResolution)
        #endif
    }

    func make(_ source: VRMKit.Material, index: Int, options: RenderOptions) throws -> Output {
        try source.validate(in: document)
        if let cached = cache[index] {
            if cached.source == source, cached.options == options { return cached.output }
            if cached.output.usesToon, source.toon != nil, options.toonShading,
               cached.source.alphaMode == source.alphaMode, cached.source.alphaCutoff == source.alphaCutoff,
               cached.source.doubleSided == source.doubleSided, cached.source.writesDepth == source.writesDepth,
               (cached.output.outline != nil) == Self.hasOutline(source, options: options) { return cached.output }
        }
        let result: Output
        #if !os(visionOS)
        if source.toon != nil, options.toonShading {
            var surface = try CustomMaterial(surfaceShader: .init(named: source.alphaMode == .mask ? "avatarToonMask" : "avatarToon", in: library),
                geometryModifier: .init(named: "avatarSurfaceVertex", in: library), lightingModel: .unlit)
            surface.baseColor.texture = .init(atlas.resource); surface.custom.texture = .init(buffer.resource)
            surface.custom.value.x = Float(index)
            surface.faceCulling = source.doubleSided ? .none : .back
            surface.blending = source.alphaMode == .blend ? .transparent(opacity: .init(scale: 1)) : .opaque
            surface.opacityThreshold = source.alphaMode == .mask ? source.alphaCutoff : nil
            surface.writesDepth = source.writesDepth; surface.readsDepth = true
            var outline: CustomMaterial?
            if Self.hasOutline(source, options: options) {
                var shell = try CustomMaterial(surfaceShader: .init(named: source.alphaMode == .mask ? "avatarOutlineMask" : "avatarOutline", in: library),
                    geometryModifier: .init(named: "avatarExpand", in: library), lightingModel: .unlit)
                shell.baseColor.texture = surface.baseColor.texture; shell.custom = surface.custom
                shell.faceCulling = .front; shell.blending = surface.blending; shell.opacityThreshold = surface.opacityThreshold
                shell.writesDepth = source.writesDepth; shell.readsDepth = true; outline = shell
            }
            result = Output(surface: surface, outline: outline, usesToon: true)
        } else { result = try standard(source) }
        #else
        result = try standard(source)
        #endif
        cache[index] = Cached(source: source, options: options, output: result); return result
    }

    private static func hasOutline(_ source: VRMKit.Material, options: RenderOptions) -> Bool {
        options.outlines && (source.toon?.outlineWidth ?? 0) > 0 && source.toon?.outlineMode != "none"
    }

    #if !os(visionOS)
    func prepare(materials: [VRMKit.Material], transforms: [Int: TextureTransform], options: RenderOptions, lights: [ToonLight], environment: ToonEnvironment) throws {
        guard materials.count == materialCount, lights.count <= options.maximumLights,
              environment.coefficients.flatMap({ [$0.x, $0.y, $0.z] }).allSatisfy(\.isFinite) else { throw VRMError.invalid("Runtime material or lighting data") }
        let values = materials + [VRMKit.Material(json: .object([:]))]
        for (index, source) in values.enumerated() {
            try source.validate(in: document)
            let base = index * MaterialLayout.stride, toon = source.toon ?? ToonSettings(json: .object(["specVersion": .string("1.0")]))
            buffer.rows[base] = source.baseColor
            buffer.rows[base + 1] = SIMD4(toon.shade.x, toon.shade.y, toon.shade.z, toon.toony)
            buffer.rows[base + 2] = SIMD4(source.emission.x, source.emission.y, source.emission.z, source.normalTexture?.strength ?? 1)
            buffer.rows[base + 3] = SIMD4(toon.rim.x, toon.rim.y, toon.rim.z, toon.rimPower)
            buffer.rows[base + 4] = SIMD4(toon.matcap.x, toon.matcap.y, toon.matcap.z, toon.rimLift)
            buffer.rows[base + 5] = SIMD4(toon.outline.x, toon.outline.y, toon.outline.z, toon.outlineWidth)
            buffer.rows[base + 6] = SIMD4(toon.shift, toon.shiftTexture?.strength ?? 1, toon.giEqualization, toon.rimLightingMix)
            buffer.rows[base + 7] = SIMD4(toon.outlineMode == "screenCoordinates" ? 2 : toon.outlineMode == "worldCoordinates" ? 1 : 0,
                toon.outlineLightingMix, source.alphaMode == .blend ? 2 : source.alphaMode == .mask ? 1 : 0, source.alphaCutoff)
            buffer.rows[base + 8] = SIMD4(toon.uvScroll.x, toon.uvScroll.y, toon.uvRotation, source.doubleSided ? 1 : 0)
            buffer.rows[base + 9] = SIMD4(source.metallic, source.roughness, source.occlusionTexture?.strength ?? 1, source.unlit ? 1 : 0)
            buffer.rows[base + 10] = SIMD4(options.exposure, options.shadows ? 1 : 0, 0, 0)
            buffer.rows[base + 11] = MaterialLayout.integer(buffer.globalRow)
            let primary = source.primaryTexture
            let scaleDelta = (transforms[index]?.scale ?? primary?.scale ?? SIMD2(repeating: 1)) - (primary?.scale ?? SIMD2(repeating: 1))
            let offsetDelta = (transforms[index]?.offset ?? primary?.offset ?? .zero) - (primary?.offset ?? .zero)
            for use in MaterialTexture.allCases {
                let row = base + MaterialLayout.textureStart + use.rawValue * MaterialLayout.textureStride
                guard let slot = source.texture(use) else {
                    for offset in 0..<MaterialLayout.textureStride { buffer.rows[row + offset] = .zero }; continue
                }
                let key = TextureAtlas.Key(texture: slot.index, color: use.isColor)
                guard let image = atlas.imageRows[key], let levels = atlas.imageLevels[key] else { throw VRMError.invalid("A runtime texture was not present at load time") }
                let sampler = try document.sampler(for: slot.index)
                buffer.rows[row] = MaterialLayout.integer(image)
                buffer.rows[row + 1] = SIMD4(Float(levels), Float(slot.texCoord), Float(Self.wrap(sampler.wrapS)), Float(Self.wrap(sampler.wrapT)))
                buffer.rows[row + 2] = SIMD4(Float(Self.filter(sampler.minFilter)), sampler.magFilter == .nearest ? 0 : 1, 0, 0)
                let scale = slot.scale + scaleDelta, offset = slot.offset + offsetDelta
                guard [scale.x, scale.y, offset.x, offset.y].allSatisfy(\.isFinite) else { throw VRMError.invalid("Runtime texture transform") }
                for (component, value) in [scale.x, scale.y, offset.x, offset.y, slot.rotation, slot.strength].enumerated() { buffer.rows[row + 3 + component] = MaterialLayout.scalar(value) }
            }
            let scalars: [Float] = [toon.toony, toon.giEqualization, toon.shift, toon.rimPower, toon.rimLift, toon.rimLightingMix,
                                   toon.outlineWidth, toon.outlineLightingMix, toon.uvScroll.x, toon.uvScroll.y, toon.uvRotation,
                                   source.normalTexture?.strength ?? 1, source.alphaCutoff, options.exposure]
            for (offset, value) in scalars.enumerated() { buffer.rows[base + 111 + offset] = MaterialLayout.scalar(value) }
        }
        buffer.rows[buffer.globalRow] = SIMD4(Float(lights.count), 0, 0, 0)
        for (index, coefficient) in environment.coefficients.enumerated() { buffer.rows[buffer.globalRow + 1 + index] = SIMD4(coefficient.x, coefficient.y, coefficient.z, 0) }
        for (index, light) in lights.enumerated() {
            try Self.validate(light)
            let row = buffer.globalRow + MaterialLayout.lightStart + index * MaterialLayout.lightStride
            buffer.rows[row] = SIMD4(light.color.x, light.color.y, light.color.z, Float(light.kind.rawValue))
            buffer.rows[row + 1] = MaterialLayout.scalar(light.position.x); buffer.rows[row + 2] = MaterialLayout.scalar(light.position.y); buffer.rows[row + 3] = MaterialLayout.scalar(light.position.z)
            let direction = VRMKit.normalized(light.direction)
            buffer.rows[row + 4] = SIMD4(direction.x, direction.y, direction.z, cos(light.innerAngle * .pi / 180))
            buffer.rows[row + 5] = SIMD4(cos(light.outerAngle * .pi / 180), light.range, light.falloff, 0)
            buffer.rows[row + 6] = .zero; buffer.rows[row + 7] = MaterialLayout.scalar(light.range)
        }
    }

    func flushParameters() throws {
        guard let command = buffer.queue.makeCommandBuffer() else { throw VRMError.invalid("Material command buffer") }
        _ = try buffer.begin(command); command.commit()
    }

    func renderShadows(lights: [ToonLight], casters: [ShadowCaster], options: RenderOptions) throws {
        try shadows.plan(lights: lights, casters: casters, options: options, buffer: buffer)
        guard let command = buffer.queue.makeCommandBuffer() else { throw VRMError.invalid("Shadow command buffer") }
        let destination = try buffer.begin(command)
        try shadows.render(casters: casters, command: command, destination: destination, buffer: buffer, images: atlas.texture.read())
        command.commit()
    }

    func bind(_ material: any RealityKit.Material, key: PrimitiveKey, time: Float) throws -> any RealityKit.Material {
        guard var custom = material as? CustomMaterial else { return material }
        guard let row = atlas.uvRows[key] else { throw VRMError.invalid("Missing primitive UV table") }
        custom.custom.value.y = time; custom.custom.value.z = Float(row & 65535); custom.custom.value.w = Float(row >> 16)
        return custom
    }

    func source(material: Int, key: PrimitiveKey, time: Float) -> ShadowCaster.Source? {
        guard let row = atlas.uvRows[key] else { return nil }
        return ShadowCaster.Source(images: atlas.texture.read(), parameters: buffer.texture.read(), material: material, uvRow: row, time: time)
    }

    private static func wrap(_ mode: TextureSampler.Wrap) -> Int { switch mode { case .clampToEdge: 0; case .repeat: 1; case .mirroredRepeat: 2 } }
    private static func filter(_ mode: TextureSampler.Filter) -> Int { switch mode { case .nearest: 0; case .linear: 1; case .nearestMipmapNearest: 2; case .linearMipmapNearest: 3; case .nearestMipmapLinear: 4; case .linearMipmapLinear: 5 } }
    private static func validate(_ light: ToonLight) throws {
        guard [light.position.x, light.position.y, light.position.z, light.direction.x, light.direction.y, light.direction.z,
               light.color.x, light.color.y, light.color.z, light.range, light.innerAngle, light.outerAngle, light.falloff].allSatisfy(\.isFinite),
              light.range > 0, light.falloff >= 0, light.innerAngle >= 0, light.outerAngle >= light.innerAngle, light.outerAngle < 90,
              light.color.x >= 0, light.color.y >= 0, light.color.z >= 0 else { throw VRMError.invalid("Toon light") }
    }
    #endif

    private func standard(_ source: VRMKit.Material) throws -> Output {
        let base = try texture(source.baseTexture, semantic: .color), tint = color(source.baseColor)
        if source.unlit || source.toon != nil {
            var material = UnlitMaterial()
            material.color = .init(tint: tint, texture: base.map { .init($0) })
            material.faceCulling = source.doubleSided ? .none : .back
            material.blending = source.alphaMode == .blend ? .transparent(opacity: .init(scale: source.baseColor.w)) : .opaque
            material.opacityThreshold = source.alphaMode == .mask ? source.alphaCutoff : nil
            return Output(surface: material, outline: nil, usesToon: false)
        }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint, texture: base.map { .init($0) })
        material.metallic = .init(floatLiteral: source.metallic); material.roughness = .init(floatLiteral: source.roughness)
        material.metallic.texture = try texture(source.metallicRoughnessTexture, semantic: .scalar, channel: 2).map { .init($0) }
        material.roughness.texture = try texture(source.metallicRoughnessTexture, semantic: .scalar, channel: 1).map { .init($0) }
        material.normal.texture = try texture(source.normalTexture, semantic: .normal).map { .init($0) }
        material.ambientOcclusion.texture = try texture(source.occlusionTexture, semantic: .scalar, channel: 0).map { .init($0) }
        let strength = max(source.emission.x, max(source.emission.y, source.emission.z))
        let emission = strength > 0 ? source.emission / strength : .zero
        material.emissiveColor = .init(color: color(SIMD4(emission.x, emission.y, emission.z, 1)), texture: try texture(source.emissionTexture, semantic: .color).map { .init($0) })
        material.emissiveIntensity = strength
        material.faceCulling = source.doubleSided ? .none : .back
        material.blending = source.alphaMode == .blend ? .transparent(opacity: .init(scale: source.baseColor.w)) : .opaque
        material.opacityThreshold = source.alphaMode == .mask ? source.alphaCutoff : nil
        return Output(surface: material, outline: nil, usesToon: false)
    }

    private func texture(_ slot: TextureSlot?, semantic: TextureResource.Semantic, channel: Int? = nil) throws -> TextureResource? {
        guard let slot else { return nil }
        let key = "\(slot.index):\(semantic):\(channel ?? -1):\(slot.strength)"
        if let cached = textures[key] { return cached }
        let json = try document.entry("textures", at: slot.index)
        guard let index = json["source"].int else { throw VRMError.unsupported("Texture image source") }
        let data = try document.image(index)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), var image = ImagePixels.decode(source, maximumDimension: maximumTextureDimension) else { throw VRMError.invalid("Image decode") }
        if channel != nil || (semantic == .normal && slot.strength != 1) {
            let pixels = try ImagePixels(data: data, color: false, maximumDimension: maximumTextureDimension)
            var rgba = [UInt8](); rgba.reserveCapacity(pixels.pixels.count * 4)
            for pixel in pixels.pixels {
                var value = pixel
                if let channel { let sample = channel == 0 ? 1 + (pixel[channel] - 1) * slot.strength : pixel[channel]; value = SIMD4(sample, sample, sample, 1) }
                else { let n = VRMKit.normalized(SIMD3((pixel.x * 2 - 1) * slot.strength, (pixel.y * 2 - 1) * slot.strength, pixel.z * 2 - 1)); value = SIMD4(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5, 1) }
                for lane in 0..<4 { rgba.append(UInt8(min(255, max(0, value[lane] * 255)).rounded())) }
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData), let converted = CGImage(width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw VRMError.invalid("Texture channel conversion") }
            image = converted
        }
        let resource = try TextureResource.generate(from: image, options: .init(semantic: semantic))
        textures[key] = resource; return resource
    }

    private func color(_ value: SIMD4<Float>) -> PlatformColor {
        let encoded = ColorSpace.sRGB(SIMD3(value.x, value.y, value.z))
        return PlatformColor(red: CGFloat(encoded.x), green: CGFloat(encoded.y), blue: CGFloat(encoded.z), alpha: 1)
    }
}
#endif
