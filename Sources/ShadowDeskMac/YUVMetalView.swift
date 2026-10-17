import AppKit
import Metal
import ShadowDeskKit
@preconcurrency import WebRTC

/// Metal-backed video renderer that samples chroma at its native resolution.
///
/// `RTCMTLNSVideoView` converts every frame through `toI420`, which would
/// downsample the chroma of a Y444 (lossless color) frame right before
/// display. This view renders the three Y/U/V planes directly: a 4:2:0 frame
/// gets bilinear chroma upsampling (same as before), a 4:4:4 frame stays
/// 1:1. Frames arrive as ``PlanarYUVBuffer`` (FFmpeg H.264) or libwebrtc's
/// own I420 buffers (VP8).
///
/// The view is only a shell: all Metal state lives in ``YUVMetalEngine``,
/// which is plain `@unchecked Sendable` — libwebrtc delivers frames on its
/// own thread and NSView's main-actor isolation must not apply there.
final class YUVMetalView: NSView {
    private let engine: YUVMetalEngine?

    override init(frame frameRect: NSRect) {
        engine = YUVMetalEngine()
        super.init(frame: frameRect)
        wantsLayer = true
        if let metalLayer = layer as? CAMetalLayer {
            engine?.attach(layer: metalLayer)
            metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    override func layout() {
        super.layout()
        engine?.updateDrawableSize(convertToBacking(bounds.size))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        engine?.updateDrawableSize(convertToBacking(bounds.size))
    }
}

// MARK: - RTCVideoRenderer

// libwebrtc delivers frames on its own thread; these stay nonisolated and
// forward to the engine instead of hopping to the main actor.
extension YUVMetalView: RTCVideoRenderer {
    nonisolated func setSize(_ size: CGSize) {
        engine?.setSize(size)
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        engine?.render(frame)
    }
}

/// All Metal rendering state and the YUV→RGB draw, safe to call from
/// libwebrtc's frame delivery thread (every mutable field sits behind `lock`).
final class YUVMetalEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textures: [String: MTLTexture] = [:]
    private var videoSize: CGSize = .zero
    private weak var metalLayer: CAMetalLayer?

    private struct ColorParams {
        var yOffset: Float
        var yScale: Float
        var rV: Float
        var gU: Float
        var gV: Float
        var bU: Float
        var uvZoom: SIMD2<Float>
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct ColorParams {
            float yOffset, yScale, rV, gU, gV, bU;
            float2 uvZoom;
        };

        struct VSOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VSOut yuvVertex(uint vid [[vertex_id]]) {
            float2 pos = float2(float((vid << 1) & 2u), float(vid & 2u)) * 2.0 - 1.0;
            VSOut result;
            result.position = float4(pos, 0, 1);
            result.uv = float2(pos.x, -pos.y) * 0.5 + 0.5;
            return result;
        }

        fragment float4 yuvFragment(
            VSOut in [[stage_in]],
            texture2d<float> yTexture [[texture(0)]],
            texture2d<float> uTexture [[texture(1)]],
            texture2d<float> vTexture [[texture(2)]],
            constant ColorParams &params [[buffer(0)]]
        ) {
            float2 uv = (in.uv - 0.5) * params.uvZoom + 0.5;
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
                return float4(0, 0, 0, 1);
            }
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float y = (yTexture.sample(s, uv).r - params.yOffset) * params.yScale;
            float u = uTexture.sample(s, uv).r - 0.5;
            float v = vTexture.sample(s, uv).r - 0.5;
            return float4(
                y + params.rV * v,
                y - params.gU * u - params.gV * v,
                y + params.bU * u,
                1.0
            );
        }
        """

    init() {
        device = MTLCreateSystemDefaultDevice()
        if let device {
            commandQueue = device.makeCommandQueue()
            pipeline = Self.makePipeline(device: device, pixelFormat: .bgra8Unorm)
        }
    }

    func attach(layer: CAMetalLayer) {
        lock.lock()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        metalLayer = layer
        lock.unlock()
    }

    func updateDrawableSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lock.lock()
        metalLayer?.drawableSize = size
        lock.unlock()
    }

    func setSize(_ size: CGSize) {
        lock.lock()
        videoSize = size
        lock.unlock()
    }

    func render(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let device, let commandQueue, let pipeline, let metalLayer,
              metalLayer.drawableSize.width > 1
        else { return }

        if let planar = frame.buffer as? PlanarYUVBuffer {
            planar.withPlanePointers { y, u, v in
                draw(
                    device: device, commandQueue: commandQueue, pipeline: pipeline, layer: metalLayer,
                    y: y, u: u, v: v,
                    width: Int(planar.width), height: Int(planar.height),
                    strideY: planar.strideY, strideU: planar.strideU, strideV: planar.strideV,
                    chromaWidth: planar.chromaWidth, chromaHeight: planar.chromaHeight,
                    colorSpace: planar.colorSpace, fullRange: planar.fullRange
                )
            }
        } else if let i420 = frame.buffer as? RTCI420BufferProtocol {
            let width = Int(i420.width), height = Int(i420.height)
            draw(
                device: device, commandQueue: commandQueue, pipeline: pipeline, layer: metalLayer,
                y: i420.dataY, u: i420.dataU, v: i420.dataV,
                width: width, height: height,
                strideY: Int(i420.strideY), strideU: Int(i420.strideU), strideV: Int(i420.strideV),
                chromaWidth: Int(i420.chromaWidth), chromaHeight: Int(i420.chromaHeight),
                colorSpace: .bt601, fullRange: false
            )
        }
    }

    // MARK: Drawing

    private func draw(
        device: MTLDevice, commandQueue: MTLCommandQueue,
        pipeline: MTLRenderPipelineState, layer: CAMetalLayer,
        y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
        width: Int, height: Int,
        strideY: Int, strideU: Int, strideV: Int,
        chromaWidth: Int, chromaHeight: Int,
        colorSpace: YUVColorSpace, fullRange: Bool
    ) {
        guard let yTexture = texture(device: device, key: "y", width: width, height: height),
              let uTexture = texture(device: device, key: "u", width: chromaWidth, height: chromaHeight),
              let vTexture = texture(device: device, key: "v", width: chromaWidth, height: chromaHeight),
              let drawable = layer.nextDrawable()
        else { return }

        yTexture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0, withBytes: y, bytesPerRow: strideY
        )
        uTexture.replace(
            region: MTLRegionMake2D(0, 0, chromaWidth, chromaHeight),
            mipmapLevel: 0, withBytes: u, bytesPerRow: strideU
        )
        vTexture.replace(
            region: MTLRegionMake2D(0, 0, chromaWidth, chromaHeight),
            mipmapLevel: 0, withBytes: v, bytesPerRow: strideV
        )

        var params = ColorParams(
            yOffset: fullRange ? 0 : 16.0 / 255.0,
            yScale: fullRange ? 1 : 255.0 / 219.0,
            rV: 0, gU: 0, gV: 0, bU: 0,
            uvZoom: uvZoom(videoWidth: width, videoHeight: height, drawable: layer.drawableSize)
        )
        // Coefficients for limited-range chroma; full-range uses the plain
        // matrix (no 224/255 headroom) with unscaled luma.
        switch (colorSpace, fullRange) {
        case (.bt601, false): params.rV = 1.596; params.gU = 0.392; params.gV = 0.813; params.bU = 2.017
        case (.bt601, true): params.rV = 1.402; params.gU = 0.3441; params.gV = 0.7141; params.bU = 1.772
        case (.bt709, _): params.rV = 1.5748; params.gU = 0.1873; params.gV = 0.4681; params.bU = 1.8556
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uTexture, index: 1)
        encoder.setFragmentTexture(vTexture, index: 2)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Aspect-fit letterboxing: uv > 1 zooms into a centered subrect, so the
    /// fragment shader samples inside the video and returns black outside.
    private func uvZoom(videoWidth: Int, videoHeight: Int, drawable: CGSize) -> SIMD2<Float> {
        let vw = Float(videoWidth), vh = Float(videoHeight)
        let dw = Float(drawable.width), dh = Float(drawable.height)
        guard vw > 0, vh > 0, dw > 0, dh > 0 else { return SIMD2(1, 1) }
        let scale = min(dw / vw, dh / vh)
        return SIMD2(dw / (vw * scale), dh / (vh * scale))
    }

    private func texture(device: MTLDevice, key: String, width: Int, height: Int) -> MTLTexture? {
        let cacheKey = "\(key)_\(width)x\(height)"
        if let cached = textures[cacheKey] { return cached }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        textures[cacheKey] = texture
        return texture
    }

    private static func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "yuvVertex"),
              let fragment = library.makeFunction(name: "yuvFragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
