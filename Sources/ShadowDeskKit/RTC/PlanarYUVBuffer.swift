@preconcurrency import WebRTC
import Foundation

/// YUV → RGB conversion coefficients carried with a frame.
public enum YUVColorSpace: Sendable {
    /// SD default; also what libwebrtc assumes for VP8.
    case bt601
    case bt709
}

/// Planar 8-bit YUV frame buffer with full chroma resolution support.
///
/// libwebrtc's ObjC buffers only cover I420/NV12, so a Y444 (4:4:4) frame
/// from the FFmpeg decoder would be chroma-downsampled by `toI420` before
/// rendering — defeating the whole point of the lossless color mode. This
/// buffer keeps the three planes at their native resolution; the renderer
/// samples chroma 1:1 when `chromaWidth == width`.
public final class PlanarYUVBuffer: NSObject, RTCVideoFrameBuffer, @unchecked Sendable {
    public let chromaWidth: Int
    public let chromaHeight: Int
    public let strideY: Int
    public let strideU: Int
    public let strideV: Int
    public let colorSpace: YUVColorSpace
    public let fullRange: Bool

    private let yPlane: [UInt8]
    private let uPlane: [UInt8]
    private let vPlane: [UInt8]

    public init(
        width: Int,
        height: Int,
        chromaWidth: Int,
        chromaHeight: Int,
        strideY: Int,
        strideU: Int,
        strideV: Int,
        yPlane: [UInt8],
        uPlane: [UInt8],
        vPlane: [UInt8],
        colorSpace: YUVColorSpace,
        fullRange: Bool
    ) {
        self.chromaWidth = chromaWidth
        self.chromaHeight = chromaHeight
        self.strideY = strideY
        self.strideU = strideU
        self.strideV = strideV
        self.yPlane = yPlane
        self.uPlane = uPlane
        self.vPlane = vPlane
        self.colorSpace = colorSpace
        self.fullRange = fullRange
        self.width = Int32(width)
        self.height = Int32(height)
    }

    // MARK: RTCVideoFrameBuffer

    public let width: Int32
    public let height: Int32

    /// Exposes the three planes for the duration of `body` only.
    public func withPlanePointers<T>(
        _ body: (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafePointer<UInt8>) -> T
    ) -> T {
        yPlane.withUnsafeBufferPointer { y in
            uPlane.withUnsafeBufferPointer { u in
                vPlane.withUnsafeBufferPointer { v in
                    body(
                        y.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!,
                        u.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!,
                        v.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
                    )
                }
            }
        }
    }

    /// Fallback for consumers that only understand I420 (thumbnails, stats).
    /// Chroma is box-filtered 2×2 when the frame is 4:4:4.
    public func toI420() -> any RTCI420BufferProtocol {
        let target = RTCI420Buffer(width: width, height: height)
        guard let mutable = target as? RTCMutableYUVPlanarBuffer else { return target }
        let w = Int(width), h = Int(height)
        let cw = (w + 1) / 2, ch = (h + 1) / 2

        withPlanePointers { srcY, srcU, srcV in
            copyPlane(
                source: srcY, sourceStride: strideY,
                destination: mutable.mutableDataY, destinationStride: Int(target.strideY),
                width: w, height: h
            )
            if chromaWidth == cw, chromaHeight == ch {
                copyPlane(
                    source: srcU, sourceStride: strideU,
                    destination: mutable.mutableDataU, destinationStride: Int(target.strideU),
                    width: cw, height: ch
                )
                copyPlane(
                    source: srcV, sourceStride: strideV,
                    destination: mutable.mutableDataV, destinationStride: Int(target.strideV),
                    width: cw, height: ch
                )
            } else {
                downsamplePlane(
                    source: srcU, sourceStride: strideU,
                    destination: mutable.mutableDataU, destinationStride: Int(target.strideU),
                    width: cw, height: ch
                )
                downsamplePlane(
                    source: srcV, sourceStride: strideV,
                    destination: mutable.mutableDataV, destinationStride: Int(target.strideV),
                    width: cw, height: ch
                )
            }
        }
        return target
    }

    private func copyPlane(
        source: UnsafePointer<UInt8>, sourceStride: Int,
        destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
        width: Int, height: Int
    ) {
        for row in 0..<height {
            memcpy(
                destination + row * destinationStride,
                source + row * sourceStride,
                width
            )
        }
    }

    /// 2×2 box downsample of a full-resolution chroma plane.
    private func downsamplePlane(
        source: UnsafePointer<UInt8>, sourceStride: Int,
        destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
        width: Int, height: Int
    ) {
        for row in 0..<height {
            for column in 0..<width {
                var sum = 0, count = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let y = row * 2 + dy, x = column * 2 + dx
                        guard y < chromaHeight, x < chromaWidth else { continue }
                        sum += Int(source[y * sourceStride + x])
                        count += 1
                    }
                }
                destination[row * destinationStride + column] = UInt8(sum / max(count, 1))
            }
        }
    }
}
