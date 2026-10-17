import CoreGraphics
import Foundation
import ImageIO

/// Decodes the remote pointer material into a `CGImage`.
///
/// The manager sends PNG for ordinary cursors and CUR/ICO containers for
/// Windows style pointers. ImageIO reads PNG but is unreliable for icon
/// containers, so containers are parsed here: PNG entries go back to ImageIO,
/// and `BITMAPINFOHEADER` entries are converted by hand.
public enum CursorImageDecoder {
    public static func image(from update: CursorUpdate) -> CGImage? {
        image(from: update.imageData)
    }

    public static func image(from data: Data) -> CGImage? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)

        if isContainer(bytes), let image = decodeContainer(bytes) {
            return image
        }
        return imageViaImageIO(data)
    }

    // MARK: - ICO / CUR containers

    /// `00 00 01 00` = icon, `00 00 02 00` = cursor.
    private static func isContainer(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 6
            && bytes[0] == 0 && bytes[1] == 0
            && (bytes[2] == 1 || bytes[2] == 2)
            && bytes[3] == 0
    }

    private static func decodeContainer(_ bytes: [UInt8]) -> CGImage? {
        let count = Int(readUInt16(bytes, 4))
        var best: (offset: Int, length: Int, width: Int, height: Int)?
        for index in 0 ..< count {
            let entry = 6 + index * 16
            guard entry + 16 <= bytes.count else { break }
            let width = bytes[entry] == 0 ? 256 : Int(bytes[entry])
            let height = bytes[entry + 1] == 0 ? 256 : Int(bytes[entry + 1])
            let length = Int(readUInt32(bytes, entry + 8))
            let offset = Int(readUInt32(bytes, entry + 12))
            guard offset >= 0, length > 0, offset + length <= bytes.count else { continue }
            if best == nil || width * height > best!.width * best!.height {
                best = (offset, length, width, height)
            }
        }
        guard let entry = best else { return nil }

        let payload = Array(bytes[entry.offset ..< entry.offset + entry.length])
        if payload.count > 8, payload[0] == 0x89, payload[1] == 0x50, payload[2] == 0x4E, payload[3] == 0x47 {
            return imageViaImageIO(Data(payload))
        }
        return decodeBitmapEntry(payload, fallbackWidth: entry.width, fallbackHeight: entry.height)
    }

    /// `BITMAPINFOHEADER` + bottom-up BGRA rows (+ an AND mask we ignore).
    private static func decodeBitmapEntry(
        _ bytes: [UInt8],
        fallbackWidth: Int,
        fallbackHeight: Int
    ) -> CGImage? {
        guard bytes.count >= 40 else { return nil }
        let headerSize = Int(readUInt32(bytes, 0))
        let headerWidth = abs(Int(readInt32(bytes, 4)))
        let headerHeight = abs(Int(readInt32(bytes, 8)))
        let bitsPerPixel = Int(readUInt16(bytes, 14))

        // Icons store the XOR bitmap followed by the AND mask, so the DIB
        // height is twice the visible height.
        let height = headerHeight / 2 > 0 ? headerHeight / 2 : fallbackHeight
        let width = headerWidth > 0 ? headerWidth : fallbackWidth
        guard width > 0, height > 0, bitsPerPixel == 32 || bitsPerPixel == 24 else { return nil }

        let bytesPerPixel = bitsPerPixel / 8
        let sourceStride = ((width * bitsPerPixel + 31) / 32) * 4
        guard headerSize + sourceStride * height <= bytes.count else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var hasAlpha = false
        for row in 0 ..< height {
            let sourceRow = headerSize + (height - 1 - row) * sourceStride
            var destination = row * width * 4
            for column in 0 ..< width {
                let source = sourceRow + column * bytesPerPixel
                let blue = bytes[source]
                let green = bytes[source + 1]
                let red = bytes[source + 2]
                let alpha: UInt8 = bitsPerPixel == 32 ? bytes[source + 3] : 255
                if alpha != 0 { hasAlpha = true }
                pixels[destination] = red
                pixels[destination + 1] = green
                pixels[destination + 2] = blue
                pixels[destination + 3] = alpha
                destination += 4
            }
        }

        // Legacy icons leave alpha at zero and rely on the AND mask; showing
        // them opaque is better than showing nothing.
        if !hasAlpha {
            for index in stride(from: 3, to: pixels.count, by: 4) {
                pixels[index] = 255
            }
        }
        return makeImage(pixels, width: width, height: height)
    }

    // MARK: - Helpers

    private static func imageViaImageIO(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        var best: CGImage?
        var bestArea = 0
        for index in 0 ..< count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let area = image.width * image.height
            if area > bestArea {
                best = image
                bestArea = area
            }
        }
        return best
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readInt32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(bytes, offset))
    }
}
