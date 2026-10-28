import Foundation

public struct ImageInfo: Sendable {
    public let width: Int
    public let height: Int
    public let mimeType: String

    /// Reads PNG or JPEG dimensions without decoding pixels or importing an image framework.
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        if bytes.count >= 24, bytes.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
           bytes[12..<16].elementsEqual([73, 72, 68, 82]) {
            func integer(_ offset: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) } }
            width = integer(16); height = integer(20); mimeType = "image/png"
        } else if bytes.count >= 4, bytes[0] == 255, bytes[1] == 216 {
            var cursor = 2, size: (Int, Int)?
            let frameMarkers: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
            while cursor < bytes.count {
                guard bytes[cursor] == 255 else { throw VRMError.invalid("JPEG marker") }
                while cursor < bytes.count, bytes[cursor] == 255 { cursor += 1 }
                guard cursor < bytes.count else { break }
                let marker = bytes[cursor]; cursor += 1
                if marker == 0xDA || marker == 0xD9 { break }
                if marker == 0x01 || (0xD0...0xD8).contains(marker) { continue }
                guard cursor + 2 <= bytes.count else { break }
                let length = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
                guard length >= 2, cursor + length <= bytes.count else { throw VRMError.invalid("JPEG segment length") }
                if frameMarkers.contains(marker), length >= 8 {
                    size = (Int(bytes[cursor + 5]) * 256 + Int(bytes[cursor + 6]), Int(bytes[cursor + 3]) * 256 + Int(bytes[cursor + 4])); break
                }
                cursor += length
            }
            guard let size else { throw VRMError.invalid("JPEG has no frame dimensions") }
            width = size.0; height = size.1; mimeType = "image/jpeg"
        } else { throw VRMError.unsupported("Thumbnail format; use PNG or JPEG") }
        guard width > 0, height > 0 else { throw VRMError.invalid("Image dimensions") }
    }
}
