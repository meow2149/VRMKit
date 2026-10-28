import Foundation

public struct AnimationTrack: Sendable {
    public enum Path: String, Sendable { case translation, rotation, scale, weights }
    public enum Interpolation: String, Sendable { case step = "STEP", linear = "LINEAR", cubic = "CUBICSPLINE" }
    public let node: Int
    public let path: Path
    public let interpolation: Interpolation
    public let times: [Float]
    public let values: [Float]
    public let components: Int

    public init(node: Int, path: Path, times: [Float], values: [Float], components: Int? = nil, interpolation: Interpolation = .linear) throws {
        let count = components ?? (path == .rotation ? 4 : 3), factor = interpolation == .cubic ? 3 : 1
        let expected = try checkedProduct(checkedProduct(times.count, max(count, 0)), factor)
        guard node >= 0, !times.isEmpty, count > 0, times[0] >= 0, times.allSatisfy(\.isFinite), values.allSatisfy(\.isFinite),
              values.count == expected,
              zip(times, times.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else { throw VRMError.invalid("Animation keyframes") }
        guard path == .weights || count == (path == .rotation ? 4 : 3) else { throw VRMError.invalid("Animation component count") }
        self.node = node; self.path = path; self.times = times; self.values = values; self.components = count; self.interpolation = interpolation
    }

    public func sample(at time: Float) -> [Float] {
        let factor = interpolation == .cubic ? 3 : 1
        func value(_ key: Int, _ slot: Int = 0) -> [Float] {
            let start = (key * factor + slot) * components
            return Array(values[start..<(start + components)])
        }
        let slot = interpolation == .cubic ? 1 : 0
        if time <= times[0] || times.count == 1 { return value(0, slot) }
        if time >= times[times.count - 1] { return value(times.count - 1, slot) }
        var low = 0, high = times.count - 1
        while high - low > 1 { let mid = (low + high) / 2; if times[mid] <= time { low = mid } else { high = mid } }
        let duration = times[high] - times[low], t = (time - times[low]) / duration
        let a = value(low, slot), b = value(high, slot)
        if interpolation == .step { return a }
        if interpolation == .linear {
            if path == .rotation {
                let q = Quaternion.slerp(Quaternion(SIMD4(a[0], a[1], a[2], a[3])), Quaternion(SIMD4(b[0], b[1], b[2], b[3])), t).vector
                return [q.x, q.y, q.z, q.w]
            }
            return zip(a, b).map { pair in pair.0 + (pair.1 - pair.0) * t }
        }
        let outgoing = value(low, 2), incoming = value(high, 0), t2 = t * t, t3 = t2 * t
        var result = (0..<components).map { (2 * t3 - 3 * t2 + 1) * a[$0] + (t3 - 2 * t2 + t) * duration * outgoing[$0]
            + (-2 * t3 + 3 * t2) * b[$0] + (t3 - t2) * duration * incoming[$0] }
        if path == .rotation { let q = Quaternion(SIMD4(result[0], result[1], result[2], result[3])).normalized.vector; result = [q.x, q.y, q.z, q.w] }
        return result
    }
}

public struct Animation: Sendable {
    public let name: String?
    public let tracks: [AnimationTrack]
    public var duration: Float { tracks.compactMap { $0.times.last }.max() ?? 0 }
    public init(name: String? = nil, tracks: [AnimationTrack]) { self.name = name; self.tracks = tracks }
}

/// Playback state belongs to one instance and can be controlled between updates.
public final class Playback {
    public let animation: Animation
    public var speed: Float = 1
    public var loops: Bool
    public var isPaused = false
    public private(set) var isStopped = false
    public private(set) var time: Float = 0
    public init(animation: Animation, loops: Bool = true) { self.animation = animation; self.loops = loops }
    public func seek(to time: Float) { if time.isFinite { self.time = min(max(0, time), animation.duration) } }
    public func stop() { isStopped = true }
    func advance(_ deltaTime: Float) {
        guard !isPaused, !isStopped, speed.isFinite else { return }
        let duration = animation.duration
        if duration == 0 { time = 0; return }
        time += deltaTime * speed
        if loops { time = time.truncatingRemainder(dividingBy: duration); if time < 0 { time += duration } }
        else { time = min(max(0, time), duration) }
    }
}

public extension Document {
    func animations() throws -> [Animation] {
        try entries("animations").map { json in
            let samplers = json["samplers"].array
            let tracks = try json["channels"].array.map { channel -> AnimationTrack in
                guard let samplerIndex = channel["sampler"].int, let node = channel["target"]["node"].int,
                      let path = AnimationTrack.Path(rawValue: channel["target"]["path"].string ?? "") else { throw VRMError.unsupported("Animation channel target") }
                let sampler = try samplers.element(at: samplerIndex, kind: "animation sampler")
                guard let input = sampler["input"].int, let output = sampler["output"].int,
                      let interpolation = AnimationTrack.Interpolation(rawValue: sampler["interpolation"].string ?? "LINEAR") else { throw VRMError.invalid("Animation sampler") }
                _ = try entry("nodes", at: node)
                let times = try accessor(input), values = try accessor(output)
                guard times.components == 1, times.count > 0 else { throw VRMError.invalid("Animation input must be a nonempty SCALAR accessor") }
                let factor = interpolation == .cubic ? 3 : 1
                let components = path == .weights ? values.values.count / (times.count * factor) : path == .rotation ? 4 : 3
                return try AnimationTrack(node: node, path: path, times: times.floats, values: values.floats, components: components, interpolation: interpolation)
            }
            return Animation(name: json["name"].string, tracks: tracks)
        }
    }
}
