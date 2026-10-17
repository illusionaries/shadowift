import FFmpegSupport
import Foundation
@preconcurrency import WebRTC

/// H.264 decoder backed by FFmpeg's libavcodec.
///
/// libwebrtc's built-in H.264 path goes through VideoToolbox, which only
/// supports 4:2:0 — the server's lossless color mode sends High 4:4:4
/// Predictive (profile 244), so decoding has to be done in software. FFmpeg
/// covers both, and I444 frames are surfaced as ``PlanarYUVBuffer`` so the
/// renderer can keep chroma at full resolution.
///
/// All entry points run on libwebrtc's decoder thread and are serialised by
/// it, so no locking happens here.
final class FFmpegH264Decoder: NSObject, RTCVideoDecoder {
    private var callback: RTCVideoDecoderCallback?
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?

    deinit {
        _ = release()
    }

    // MARK: RTCVideoDecoder

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        _ = release()
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264),
              let context = avcodec_alloc_context3(codec)
        else { return -1 }

        // Slice threading: parallel work inside one frame without the output
        // delay frame threading would add.
        context.pointee.thread_count = numberOfCores
        context.pointee.thread_type = Int32(FF_THREAD_SLICE)
        context.pointee.flags |= AV_CODEC_FLAG_LOW_DELAY
        context.pointee.err_recognition = 0

        guard avcodec_open2(context, codec, nil) >= 0 else {
            var stale: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&stale)
            return -1
        }
        self.context = context
        packet = av_packet_alloc()
        frame = av_frame_alloc()
        guard packet != nil, frame != nil else {
            _ = release()
            return -1
        }
        return 0
    }

    func release() -> Int {
        if let context {
            var stale: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&stale)
        }
        context = nil
        if let packet {
            var stale: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&stale)
        }
        packet = nil
        if let frame {
            var stale: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&stale)
        }
        frame = nil
        return 0
    }

    func decode(
        _ encodedImage: RTCEncodedImage,
        missingFrames: Bool,
        codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
        renderTimeMs: Int64
    ) -> Int {
        guard let context, let packet, let frame else { return -1 }
        let bitstream = encodedImage.buffer
        guard !bitstream.isEmpty else { return 0 }

        // libwebrtc hands H.264 over as one complete Annex B access unit per
        // call; the FFmpeg decoder consumes that directly. av_new_packet
        // copies, so the NSData is not aliased.
        av_packet_unref(packet)
        guard av_new_packet(packet, Int32(bitstream.count)) == 0 else { return -1 }
        bitstream.copyBytes(to: packet.pointee.data, count: bitstream.count)

        guard avcodec_send_packet(context, packet) >= 0 else {
            av_packet_unref(packet)
            return -1
        }
        av_packet_unref(packet)

        while avcodec_receive_frame(context, frame) == 0 {
            emit(frame, timeStamp: encodedImage.timeStamp)
            av_frame_unref(frame)
        }
        return 0
    }

    func implementationName() -> String { "FFmpeg" }

    // MARK: Frame conversion

    private func emit(_ frame: UnsafeMutablePointer<AVFrame>, timeStamp: UInt32) {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return }

        let chromaWidth: Int
        let chromaHeight: Int
        switch AVPixelFormat(rawValue: frame.pointee.format) {
        case AV_PIX_FMT_YUV420P:
            chromaWidth = (width + 1) / 2
            chromaHeight = (height + 1) / 2
        case AV_PIX_FMT_YUV444P:
            chromaWidth = width
            chromaHeight = height
        default:
            // NV12 / 10-bit never appear on the x264enc Y444 pipeline.
            return
        }

        let buffer = PlanarYUVBuffer(
            width: width,
            height: height,
            chromaWidth: chromaWidth,
            chromaHeight: chromaHeight,
            strideY: width,
            strideU: chromaWidth,
            strideV: chromaWidth,
            yPlane: copyPlane(frame.pointee.data.0, linesize: Int(frame.pointee.linesize.0), width: width, height: height),
            uPlane: copyPlane(frame.pointee.data.1, linesize: Int(frame.pointee.linesize.1), width: chromaWidth, height: chromaHeight),
            vPlane: copyPlane(frame.pointee.data.2, linesize: Int(frame.pointee.linesize.2), width: chromaWidth, height: chromaHeight),
            colorSpace: frame.pointee.colorspace == AVCOL_SPC_BT709 ? .bt709 : .bt601,
            fullRange: frame.pointee.color_range == AVCOL_RANGE_JPEG
        )

        let videoFrame = RTCVideoFrame(
            buffer: buffer,
            rotation: ._0,
            timeStampNs: Int64(timeStamp) * 1_000_000 / 90
        )
        videoFrame.timeStamp = Int32(bitPattern: timeStamp)
        callback?(videoFrame)
    }

    private func copyPlane(
        _ source: UnsafeMutablePointer<UInt8>?,
        linesize: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard let source, linesize > 0 else { return [UInt8](repeating: 128, count: width * height) }
        if linesize == width {
            let count = width * height
            return [UInt8](UnsafeBufferPointer(start: source, count: count))
        }
        var plane = [UInt8](repeating: 0, count: width * height)
        plane.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(base + row * width, source + row * linesize, width)
            }
        }
        return plane
    }
}
