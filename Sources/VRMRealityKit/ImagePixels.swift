#if canImport(RealityKit)
import Foundation
import CoreGraphics
import ImageIO
import VRMKit

struct ImagePixels {
    let width: Int
    let height: Int
    var pixels: [SIMD4<Float>]

    init(data: Data, color: Bool, maximumDimension: Int) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              maximumDimension > 0, let image = Self.decode(source, maximumDimension: maximumDimension) else { throw VRMError.invalid("Image cannot be decoded") }
        let ratio = min(1, Float(maximumDimension) / Float(max(image.width, image.height)))
        width = max(1, Int(Float(image.width) * ratio)); height = max(1, Int(Float(image.height) * ratio))
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, count <= Int.max / 16 else { throw VRMError.invalid("Image dimensions") }
        pixels = Array(repeating: .zero, count: count)
        if color {
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw VRMError.invalid("Linear color space") }
            let succeeded = pixels.withUnsafeMutableBytes { bytes -> Bool in
                let flags = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 32,
                    bytesPerRow: width * 16, space: space, bitmapInfo: flags) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            guard succeeded else { throw VRMError.invalid("Linear texture conversion") }
            for index in pixels.indices {
                let alpha = pixels[index].w
                if alpha > 0 { pixels[index].x /= alpha; pixels[index].y /= alpha; pixels[index].z /= alpha }
            }
        } else if width == image.width, height == image.height, let raw = Self.rawPixels(image) {
            pixels = raw
        } else {
            var bytes = Array(repeating: UInt8(0), count: count * 4)
            let succeeded = bytes.withUnsafeMutableBytes { memory -> Bool in
                let space = CGColorSpaceCreateDeviceRGB()
                guard let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image.copy(colorSpace: space) ?? image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            guard succeeded else { throw VRMError.invalid("Data texture conversion") }
            for index in pixels.indices {
                let alpha = Float(bytes[index * 4 + 3]) / 255, divisor = max(alpha * 255, 1)
                pixels[index] = SIMD4(Float(bytes[index * 4]) / divisor, Float(bytes[index * 4 + 1]) / divisor, Float(bytes[index * 4 + 2]) / divisor, alpha)
            }
        }
    }

    init(width: Int, height: Int, pixels: [SIMD4<Float>]) { self.width = width; self.height = height; self.pixels = pixels }

    static func decode(_ source: CGImageSource, maximumDimension: Int) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if max(width, height) > maximumDimension {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: maximumDimension]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // Read data images without ICC/gamma conversion or a premultiplying drawing pass.
    private static func rawPixels(_ image: CGImage) -> [SIMD4<Float>]? {
        let bits = image.bitsPerComponent, bytes = bits / 8
        guard [8, 16].contains(bits), let model = image.colorSpace?.model,
              model == .rgb || model == .monochrome,
              image.bitsPerPixel % bits == 0, let provider = image.dataProvider,
              let data = CGDataProviderCopyData(provider), let memory = CFDataGetBytePtr(data) else { return nil }
        let channels = image.bitsPerPixel / bits, colors = model == .rgb ? 3 : 1
        guard channels == colors || channels == colors + 1,
              image.bytesPerRow >= image.width * channels * bytes,
              CFDataGetLength(data) >= image.bytesPerRow * image.height else { return nil }
        let alpha = image.alphaInfo
        let first = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let hasAlpha = alpha == .first || alpha == .last || premultiplied
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let reverse = bits == 8 && channels == 4 && order == .byteOrder32Little
        let little = bits == 16 && order == .byteOrder16Little
        var result = Array(repeating: SIMD4<Float>.zero, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * channels * bytes
                func sample(_ channel: Int) -> Float {
                    let index = offset + (reverse ? channels - 1 - channel : channel) * bytes
                    if bits == 8 { return Float(memory[index]) / 255 }
                    let a = UInt16(memory[index]), b = UInt16(memory[index + 1])
                    return Float(little ? a | (b << 8) : (a << 8) | b) / 65535
                }
                let start = first ? 1 : 0, a = hasAlpha ? sample(first ? 0 : channels - 1) : 1
                var rgb = model == .rgb ? SIMD3(sample(start), sample(start + 1), sample(start + 2)) : SIMD3(repeating: sample(start))
                if premultiplied, a > 0 { rgb /= a }
                result[y * image.width + x] = SIMD4(rgb.x, rgb.y, rgb.z, a)
            }
        }
        return result
    }

    func mipmaps(color: Bool) -> [ImagePixels] {
        var levels = [self]
        while let previous = levels.last, previous.width > 1 || previous.height > 1 {
            let width = max(1, previous.width / 2), height = max(1, previous.height / 2)
            var pixels = Array(repeating: SIMD4<Float>.zero, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var sum = SIMD4<Float>.zero
                    // Area sampling also includes the trailing row/column of odd-sized images.
                    let x0 = x * previous.width / width, x1 = (x + 1) * previous.width / width
                    let y0 = y * previous.height / height, y1 = (y + 1) * previous.height / height
                    for sy in y0..<y1 { for sx in x0..<x1 {
                        var value = previous.pixels[sy * previous.width + sx]
                        if color { value.x *= value.w; value.y *= value.w; value.z *= value.w }
                        sum += value
                    } }
                    sum /= Float((x1 - x0) * (y1 - y0))
                    if color, sum.w > 0 { sum.x /= sum.w; sum.y /= sum.w; sum.z /= sum.w }
                    pixels[y * width + x] = sum
                }
            }
            levels.append(ImagePixels(width: width, height: height, pixels: pixels))
        }
        return levels
    }
}
#endif
