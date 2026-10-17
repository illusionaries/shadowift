@preconcurrency import WebRTC
import Foundation

/// Decoder factory that routes H.264 to the FFmpeg decoder (the only way to
/// decode the lossless-color 4:4:4 stream — VideoToolbox tops out at 4:2:0)
/// and leaves every other codec to libwebrtc's default software decoders.
public final class ShadowDeskVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let fallback = RTCDefaultVideoDecoderFactory()

    /// The default factory's list already advertises H.264, plus one extra
    /// H.264 entry without `packetization-mode`: libwebrtc treats a missing
    /// `packetization-mode` as "0" (RFC 6184), and some ShadowDesk workers
    /// offer H.264 with a bare `aggregate-mode=zero-latency` fmtp. Without a
    /// packetization-mode-0 entry on our side the codec match fails and the
    /// video m-section gets rejected. The decoders themselves don't care —
    /// FFmpeg handles every packetization mode.
    public func supportedCodecs() -> [RTCVideoCodecInfo] {
        let codecs = fallback.supportedCodecs()
        guard let h264 = codecs.first(where: { $0.name == "H264" }),
              h264.parameters["packetization-mode"] != nil
        else { return codecs }
        var packetizationModeZero = h264.parameters
        packetizationModeZero.removeValue(forKey: "packetization-mode")
        return codecs + [RTCVideoCodecInfo(name: h264.name, parameters: packetizationModeZero)]
    }

    public func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        if info.name == "H264" {
            return FFmpegH264Decoder()
        }
        return fallback.createDecoder(info)
    }
}
