import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import WebRTC

import ShadowDeskKit

/// Headless end-to-end check: login → signalling → WebRTC → first decoded
/// frame. Mirrors what the macOS app does, minus the UI.
@main
struct ShadowProbe {
    static func main() async {
        let options: Options
        do {
            options = try Options.parse(CommandLine.arguments)
        } catch {
            print("shadowprobe: \(error.localizedDescription)")
            print(Options.usage)
            exit(2)
        }

        print("[probe] server  \(options.server!)")
        print("[probe] account \(options.user)")

        let grabber = FrameGrabber()
        let client = ShadowDeskClient(configuration: .init(
            server: options.server!,
            user: options.user,
            password: options.password
        ))

        let printer = Task {
            for await event in await client.events() {
                switch event {
                case let .log(message):
                    print("[kit]   \(message)")
                case let .stateChanged(state):
                    print("[state] \(state)")
                    if state == .connected {
                        // Attach again once media is flowing: the wrapper obtained
                        // at offer time can be too early on some libwebrtc builds.
                        Task {
                            try? await Task.sleep(for: .milliseconds(800))
                            for track in await client.videoTracks() {
                                track.attach(grabber)
                            }
                        }
                    }
                case let .serverConfig(config):
                    if let size = config.resolutionSize {
                        print("[probe] remote capture \(size.width)x\(size.height), " +
                              "\(config.framerate ?? 0) fps, \(config.videoBitrate ?? 0) kbps")
                    }
                case let .latency(milliseconds):
                    print("[probe] control RTT \(milliseconds) ms")
                case let .videoTrack(track):
                    print("[probe] video track attached")
                    track.attach(grabber)

                case .controlChannelReady:
                    print("[probe] control channel ready")
                    if let resolution = options.resolution {
                        // The app always asks adaptively, mirror that here.
                        _ = await client.send(.resolution(
                            width: resolution.width,
                            height: resolution.height,
                            adaptive: true
                        ))
                    }
                    if options.input {
                        _ = await client.send(.mouseMove(x: 100, y: 100))
                        _ = await client.send(.mouseMove(x: 300, y: 200))
                    }
                    if let clipboard = options.clipboard {
                        _ = await client.send(.clipboard(clipboard))
                        print("[probe] pushed clipboard: \(clipboard)")
                    }
                case let .clipboard(content):
                    print("[probe] clipboard: \(content.prefix(60))")
                case let .cursor(update):
                    print("[probe] cursor serial=\(update.serial) visible=\(update.visible) " +
                          "bytes=\(update.imageData.count) hotspot=\(update.hotSpotX),\(update.hotSpotY)")
                case let .ended(reason):
                    print("[probe] ended: \(reason ?? "closed")")
                }
            }
        }

        do {
            try await client.start()
        } catch {
            print("[probe] failed: \(error.localizedDescription)")
            printer.cancel()
            exit(1)
        }

        let deadline = ContinuousClock.now + .seconds(options.seconds)
        var statsTick = 0
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            statsTick += 1
            if statsTick % 10 == 0, let stats = await client.mediaStats() {
                print("[stats] rx=\(stats.bytesReceived)B frames=\(stats.framesDecoded)/\(stats.framesReceived) " +
                      "keyframes=\(stats.keyFramesDecoded) size=\(stats.frameWidth)x\(stats.frameHeight)")
            }
            if await client.state == .closed { break }
        }

        if let dump = options.dump {
            if let frame = grabber.latestFrame, let image = RGBConverter.image(from: frame) {
                do {
                    try RGBConverter.writePNG(image, to: dump)
                    print("[probe] wrote \(image.width)x\(image.height) frame to \(dump.path)")
                } catch {
                    print("[probe] could not write \(dump.path): \(error.localizedDescription)")
                }
            } else {
                print("[probe] no decoded frame to dump")
            }
        }

        if let frame = grabber.latestFrame {
            print("[probe] decoded frame: \(Int(frame.width))x\(Int(frame.height))")
        } else {
            print("[probe] no frame decoded within \(options.seconds)s")
        }

        await client.stop()
        printer.cancel()
        exit(0)
    }
}

// MARK: - Options

struct Options {
    var server: URL?
    var user = ""
    var password = ""
    var seconds: Double = 12
    var dump: URL?
    var resolution: ServerConfig.VideoSize?
    var clipboard: String?
    var input = false

    static let usage = """
    usage: shadowprobe --user <account> [options]
      --server <url>       server root (required, e.g. https://example.com/shadowdesk)
      --user <account>     login id
      --password <pw>      password (default: $SHADOWDESK_PASSWORD, then the keychain)
      --seconds <n>        how long to stay connected (default 12)
      --dump <file.png>    save the last decoded frame
      --resolution <WxH>   ask the agent for a capture size
      --input              send a small mouse movement after connecting
      --clipboard <text>   push text to the remote clipboard after connecting
    """

    enum ParseError: LocalizedError {
        case missing(String)
        case badValue(String, String)

        var errorDescription: String? {
            switch self {
            case let .missing(flag): "--\(flag) needs a value"
            case let .badValue(flag, value): "invalid value for --\(flag): \(value)"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--server":
                guard let value = iterator.next() else { throw ParseError.missing("server") }
                guard let url = ServerAddress.normalize(value) else {
                    throw ParseError.badValue("server", value)
                }
                options.server = url
            case "--user":
                options.user = iterator.next() ?? ""
            case "--password":
                options.password = iterator.next() ?? ""
            case "--seconds":
                guard let value = iterator.next(), let seconds = Double(value) else {
                    throw ParseError.badValue("seconds", "?")
                }
                options.seconds = seconds
            case "--dump":
                guard let value = iterator.next() else { throw ParseError.missing("dump") }
                options.dump = URL(fileURLWithPath: value)
            case "--resolution":
                guard let value = iterator.next(), let size = ServerConfig.VideoSize(string: value) else {
                    throw ParseError.badValue("resolution", "?")
                }
                options.resolution = size
            case "--input":
                options.input = true
            case "--clipboard":
                options.clipboard = iterator.next()
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw ParseError.badValue("flag", argument)
            }
        }
        guard let server = options.server else { throw ParseError.missing("server") }
        guard !options.user.isEmpty else { throw ParseError.missing("user") }
        if options.password.isEmpty {
            options.password = ProcessInfo.processInfo.environment["SHADOWDESK_PASSWORD"] ?? ""
        }
        if options.password.isEmpty {
            options.password = Keychain.password(
                service: Keychain.service(for: server),
                account: options.user
            ) ?? ""
        }
        guard !options.password.isEmpty else {
            throw ParseError.missing("password (also absent from the keychain)")
        }
        return options
    }
}

// MARK: - Frame capture

/// Collects the newest decoded frame so the probe can dump it.
final class FrameGrabber: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: RTCVideoFrame?
    private(set) var renderCount = 0

    var latestFrame: RTCVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        self.frame = frame
        renderCount += 1
        lock.unlock()
    }
}

/// I420 (limited range BT.601) to RGB, for the PNG dump only. The app renders
/// through `RTCMTLNSVideoView` and never touches pixels.
enum RGBConverter {
    static func image(from frame: RTCVideoFrame) -> CGImage? {
        let buffer = frame.buffer.toI420()
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        guard width > 0, height > 0 else { return nil }

        let strideY = Int(buffer.strideY)
        let strideU = Int(buffer.strideU)
        let strideV = Int(buffer.strideV)
        let y = buffer.dataY
        let u = buffer.dataU
        let v = buffer.dataV

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let yRow = y + row * strideY
            let chromaRow = row / 2
            let uRow = u + chromaRow * strideU
            let vRow = v + chromaRow * strideV
            var out = row * width * 4
            for column in 0..<width {
                let c = max(0, Int(yRow[column]) - 16)
                let d = Int(uRow[column / 2]) - 128
                let e = Int(vRow[column / 2]) - 128
                rgba[out + 0] = UInt8(clamping: (298 * c + 409 * e + 128) >> 8)
                rgba[out + 1] = UInt8(clamping: (298 * c - 100 * d - 208 * e + 128) >> 8)
                rgba[out + 2] = UInt8(clamping: (298 * c + 516 * d + 128) >> 8)
                rgba[out + 3] = 255
                out += 4
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
