import Foundation

public enum ColorSpace {
    public static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    public static func sRGB(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
    public static func linear(_ value: SIMD3<Float>) -> SIMD3<Float> { SIMD3(linear(value.x), linear(value.y), linear(value.z)) }
    public static func sRGB(_ value: SIMD3<Float>) -> SIMD3<Float> { SIMD3(sRGB(value.x), sRGB(value.y), sRGB(value.z)) }
}

/// Diffuse spherical-harmonic coefficients in world coordinates, already convolved by cosine / pi.
public struct ToonEnvironment: Equatable, Sendable {
    public let coefficients: [SIMD3<Float>]
    public init(ambient: SIMD3<Float> = SIMD3(repeating: 0.25)) {
        coefficients = [ambient / 0.282095] + Array(repeating: .zero, count: 8)
    }
    public init(coefficients: [SIMD3<Float>]) throws {
        guard coefficients.count == 9, coefficients.flatMap({ [$0.x, $0.y, $0.z] }).allSatisfy(\.isFinite) else { throw VRMError.invalid("Nine finite SH coefficients are required") }
        self.coefficients = coefficients
    }
    public func irradiance(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let basis = Self.basis(normalized(direction))
        return zip(coefficients, basis).reduce(.zero) { $0 + $1.0 * $1.1 }
    }
    public static func basis(_ n: SIMD3<Float>) -> [Float] {
        [0.282095, 0.488603 * n.y, 0.488603 * n.z, 0.488603 * n.x,
         1.092548 * n.x * n.y, 1.092548 * n.y * n.z, 0.315392 * (3 * n.z * n.z - 1),
         1.092548 * n.x * n.z, 0.546274 * (n.x * n.x - n.y * n.y)]
    }
    /// Projects a linear RGB equirectangular image into diffuse SH lighting.
    public init(pixels: [SIMD3<Float>], width: Int, height: Int, intensity: Float = 1, rotation: Float = 0) throws {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixels.count == count, intensity.isFinite, intensity >= 0, rotation.isFinite else { throw VRMError.invalid("Environment image") }
        var result = Array(repeating: SIMD3<Float>.zero, count: 9), total: Float = 0
        for y in 0..<height {
            let theta = (Float(y) + 0.5) / Float(height) * .pi, weight = sin(theta)
            for x in 0..<width {
                let phi = (Float(x) + 0.5) / Float(width) * 2 * .pi + rotation
                let direction = SIMD3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi))
                let basis = Self.basis(direction), pixel = pixels[y * width + x]
                guard [pixel.x, pixel.y, pixel.z].allSatisfy(\.isFinite) else { throw VRMError.invalid("Environment pixel") }
                for index in 0..<9 { result[index] += pixel * basis[index] * weight }
                total += weight
            }
        }
        for index in 0..<9 {
            let convolution: Float = index == 0 ? 1 : index < 4 ? 2 / 3 : 1 / 4
            result[index] *= 4 * .pi / max(total, 0.000001) * convolution * intensity
        }
        guard result.flatMap({ [$0.x, $0.y, $0.z] }).allSatisfy(\.isFinite) else { throw VRMError.invalid("Environment intensity overflow") }
        coefficients = result
    }
}
