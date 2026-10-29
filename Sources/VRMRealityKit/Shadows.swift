#if canImport(RealityKit) && !os(visionOS)
import Foundation
import Metal
import RealityKit
import simd
import VRMKit

struct ShadowCaster {
    struct Source {
        let images: any MTLTexture
        let parameters: any MTLTexture
        let material: Int
        let uvRow: Int
        let time: Float
    }
    let geometry: Geometry
    let transform: Matrix4
    let doubleSided: Bool
    let originalTriangles: [UInt32]
    let source: Source?
}

@MainActor
final class ShadowRenderer {
    struct Face { let matrix: Matrix4; let index: Int }
    let device: any MTLDevice
    let pipeline: any MTLRenderPipelineState
    let depthState: any MTLDepthStencilState
    let color: any MTLTexture
    let depth: any MTLTexture
    var faces: [Face] = []

    init(device: any MTLDevice, library: any MTLLibrary, resolution: Int) throws {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "avatarShadowVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "avatarShadowFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float; descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let state = MTLDepthStencilDescriptor(); state.depthCompareFunction = .lessEqual; state.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: state) else { throw VRMError.invalid("Shadow depth state") }
        self.depthState = depthState
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: resolution, height: resolution, mipmapped: false)
        target.storageMode = .private; target.usage = [.renderTarget, .shaderRead]
        guard let color = device.makeTexture(descriptor: target) else { throw VRMError.invalid("Shadow color target") }
        self.color = color
        target.pixelFormat = .depth32Float; target.usage = [.renderTarget]
        guard let depth = device.makeTexture(descriptor: target) else { throw VRMError.invalid("Shadow depth target") }
        self.depth = depth
    }

    func plan(lights: [ToonLight], casters: [ShadowCaster], options: RenderOptions, buffer: MaterialBuffer) throws {
        faces.removeAll(keepingCapacity: true)
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude), maximum = -minimum
        var hasBounds = false
        for caster in casters where !caster.geometry.triangles.isEmpty {
            for point in caster.geometry.positions {
                let world = caster.transform.point(point)
                guard [world.x, world.y, world.z].allSatisfy(\.isFinite) else { throw VRMError.invalid("Shadow caster transform or position") }
                hasBounds = true
                for lane in 0..<3 { minimum[lane] = min(minimum[lane], world[lane]); maximum[lane] = max(maximum[lane], world[lane]) }
            }
        }
        if !hasBounds { minimum = SIMD3(-1, -1, -1); maximum = SIMD3(1, 1, 1) }
        for (index, light) in lights.enumerated() {
            let row = buffer.globalRow + MaterialLayout.lightStart + index * MaterialLayout.lightStride
            buffer.rows[row + 5].w = 0
            if !options.shadows || !light.castsShadow { continue }
            let count = light.kind == .point ? 6 : 1
            if faces.count + count > buffer.shadowRects.count { continue }
            let start = faces.count, matrices: [Matrix4]
            switch light.kind {
            case .directional:
                let center = (minimum + maximum) / 2, radius = max(length(maximum - minimum), 0.1)
                let direction = VRMKit.normalized(light.direction)
                let view = Self.view(eye: center - direction * radius, direction: direction)
                let corners = Self.corners(minimum, maximum).map { view.point($0) }
                let xs = corners.map(\.x), ys = corners.map(\.y), zs = corners.map(\.z)
                let padding = max(0.02, radius * 0.02)
                let left = xs.min()! - padding, right = xs.max()! + padding
                let bottom = ys.min()! - padding, top = ys.max()! + padding
                let near = max(0.001, -zs.max()! - padding), far = max(near + 0.01, -zs.min()! + padding)
                matrices = [Self.orthographic(left: left, right: right, bottom: bottom, top: top, near: near, far: far) * view]
            case .spot:
                let projection = Self.perspective(angle: min(179, max(1, light.outerAngle * 2)), near: 0.01, far: max(0.02, light.range))
                matrices = [projection * Self.view(eye: light.position, direction: VRMKit.normalized(light.direction))]
            case .point:
                let directions: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
                let projection = Self.perspective(angle: 90, near: 0.01, far: max(0.02, light.range))
                matrices = directions.map { projection * Self.view(eye: light.position, direction: $0) }
            }
            let descriptor = buffer.shadowRow + start * MaterialLayout.shadowStride
            buffer.rows[row + 5].w = Float(count)
            buffer.rows[row + 6] = MaterialLayout.integer(descriptor)
            for matrix in matrices {
                let face = faces.count, rect = buffer.shadowRects[face], base = buffer.shadowRow + face * MaterialLayout.shadowStride
                buffer.rows[base] = MaterialLayout.pair(rect.x, rect.y); buffer.rows[base + 1] = MaterialLayout.pair(rect.width, rect.height)
                buffer.rows[base + 2] = SIMD4(options.shadowBias, options.shadowNormalBias, options.shadowStrength, 0)
                let columns = [matrix.c0, matrix.c1, matrix.c2, matrix.c3]
                for column in 0..<4 { for lane in 0..<4 { buffer.rows[base + 3 + column * 4 + lane] = MaterialLayout.scalar(columns[column][lane]) } }
                faces.append(Face(matrix: matrix, index: face))
            }
        }
    }

    func render(casters: [ShadowCaster], command: any MTLCommandBuffer, destination: any MTLTexture, buffer: MaterialBuffer, images: any MTLTexture) throws {
        if faces.isEmpty { return }
        struct Prepared { let caster: ShadowCaster; let vertices: any MTLBuffer; let count: Int }
        let prepared = try casters.compactMap { caster -> Prepared? in
            if caster.geometry.triangles.isEmpty { return nil }
            var values: [Float] = []
            values.reserveCapacity(caster.geometry.triangles.count * 8)
            let ids = try Self.triangleIDs(caster.geometry.triangles, original: caster.originalTriangles)
            for (triangle, id) in ids.enumerated() {
                for lane in 0..<3 {
                    let index = Int(caster.geometry.triangles[triangle * 3 + lane])
                    guard caster.geometry.positions.indices.contains(index) else { throw VRMError.invalid("Shadow triangle index") }
                    let point = caster.transform.point(caster.geometry.positions[index])
                    let u: Float = lane == 1 ? 1 : 0, v: Float = lane == 2 ? 1 : 0
                    values += [point.x, point.y, point.z, 1, u, v, Float(id), 0]
                }
            }
            guard !values.isEmpty else { return nil }
            let vertices = values.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared) }
            guard let vertices else { throw VRMError.invalid("Shadow vertex allocation") }
            return Prepared(caster: caster, vertices: vertices, count: values.count / 8)
        }
        for face in faces {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw VRMError.invalid("Shadow render encoder") }
            encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
            var matrix = simd_float4x4(columns: (face.matrix.c0, face.matrix.c1, face.matrix.c2, face.matrix.c3))
            encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            for item in prepared {
                let caster = item.caster
                let determinant = dot(cross(SIMD3(caster.transform.c0.x, caster.transform.c0.y, caster.transform.c0.z), SIMD3(caster.transform.c1.x, caster.transform.c1.y, caster.transform.c1.z)), SIMD3(caster.transform.c2.x, caster.transform.c2.y, caster.transform.c2.z))
                encoder.setFrontFacing(determinant < 0 ? .clockwise : .counterClockwise)
                encoder.setCullMode(caster.doubleSided ? .none : .back)
                encoder.setVertexBuffer(item.vertices, offset: 0, index: 0)
                encoder.setFragmentTexture(caster.source?.images ?? images, index: 0)
                encoder.setFragmentTexture(caster.source?.parameters ?? destination, index: 1)
                var uniforms = SIMD4<UInt32>((caster.source?.time ?? 0).bitPattern,
                    UInt32(bitPattern: Int32(caster.source?.material ?? -1)), UInt32(caster.source?.uvRow ?? 0), 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: item.count)
            }
            encoder.endEncoding()
            guard let blit = command.makeBlitCommandEncoder() else { throw VRMError.invalid("Shadow atlas encoder") }
            let rect = buffer.shadowRects[face.index]
            blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: rect.width, height: rect.height, depth: 1), to: destination,
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: rect.x, y: rect.y, z: 0))
            blit.endEncoding()
        }
    }

    static func triangleIDs(_ triangles: [UInt32], original: [UInt32]) throws -> [Int] {
        guard triangles.count % 3 == 0, original.count % 3 == 0 else { throw VRMError.invalid("Triangle index count") }
        if triangles == original { return Array(0..<(triangles.count / 3)) }
        if original.isEmpty { return Array(0..<(triangles.count / 3)) }
        var cursor = 0, ids: [Int] = []
        for start in stride(from: 0, to: triangles.count - triangles.count % 3, by: 3) {
            while cursor + 2 < original.count {
                let equal = (0..<3).allSatisfy { triangles[start + $0] == original[cursor + $0] }
                let id = cursor / 3; cursor += 3
                if equal { ids.append(id); break }
            }
        }
        guard ids.count == triangles.count / 3 else { throw VRMError.invalid("Filtered triangles must preserve their original order") }
        return ids
    }

    private static func corners(_ minimum: SIMD3<Float>, _ maximum: SIMD3<Float>) -> [SIMD3<Float>] {
        (0..<8).map { SIMD3($0 & 1 == 0 ? minimum.x : maximum.x, $0 & 2 == 0 ? minimum.y : maximum.y, $0 & 4 == 0 ? minimum.z : maximum.z) }
    }
    private static func view(eye: SIMD3<Float>, direction: SIMD3<Float>) -> Matrix4 {
        let up = abs(direction.y) > 0.95 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        let right = VRMKit.normalized(cross(direction, up)), vertical = cross(right, direction)
        return Matrix4([right.x, vertical.x, -direction.x, 0, right.y, vertical.y, -direction.y, 0,
                        right.z, vertical.z, -direction.z, 0, -dot(right, eye), -dot(vertical, eye), dot(direction, eye), 1])
    }
    private static func perspective(angle: Float, near: Float, far: Float) -> Matrix4 {
        let scale = 1 / tan(angle * .pi / 360)
        return Matrix4([scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, far / (near - far), -1, 0, 0, near * far / (near - far), 0])
    }
    private static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> Matrix4 {
        Matrix4([2 / (right - left), 0, 0, 0, 0, 2 / (top - bottom), 0, 0, 0, 0, 1 / (near - far), 0,
                 -(right + left) / (right - left), -(top + bottom) / (top - bottom), near / (near - far), 1])
    }
}
#endif
