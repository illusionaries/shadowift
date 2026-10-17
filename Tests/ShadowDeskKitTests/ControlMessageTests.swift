import Foundation
import Testing

@testable import ShadowDeskKit

@Suite("Control channel messages")
struct ControlMessageTests {
    @Test("config snapshot")
    func config() throws {
        let json = #"""
        {"type":"config","data":{"userId":"acct","framerate":30,"video_bitrate":16000,
         "enable_dynamic_framerate":true,"video_format":"I420","encoder":"vp8enc",
         "resolution":"1920x1080","enableAdaptiveResolution":false,"enableClipboard":true,
         "enable_audio":false,"curUsersNum":1}}
        """#
        let message = try #require(ControlMessage.decode(json))
        guard case let .serverConfig(config) = message else {
            Issue.record("expected a server config, got \(message)")
            return
        }
        #expect(config.userID == "acct")
        #expect(config.framerate == 30)
        #expect(config.videoBitrate == 16000)
        #expect(config.dynamicFramerate == true)
        #expect(config.resolutionSize == .init(width: 1920, height: 1080))
        #expect(config.adaptiveResolution == false)
        #expect(config.clipboardEnabled == true)
        #expect(config.viewerCount == 1)
    }

    @Test("a partial config layers over the previous snapshot")
    func partialConfigMerge() throws {
        let full = try #require(ControlMessage.decode(#"""
        {"type":"config","data":{"userId":"acct","video_format":"Y444",
         "video_formats":["I420","Y444"],"encoder":"x264enc","resolution":"1718x1078"}}
        """#))
        guard case let .serverConfig(base) = full else {
            Issue.record("expected a server config")
            return
        }

        // The manager answers a resize with only the resolution field set.
        let partial = try #require(ControlMessage.decode(
            #"{"type":"config","data":{"resolution":"1280x792"}}"#
        ))
        guard case let .serverConfig(update) = partial else {
            Issue.record("expected a server config")
            return
        }

        let merged = update.merged(over: base)
        #expect(merged.resolutionSize == .init(width: 1280, height: 792))
        #expect(merged.videoFormat == "Y444")
        #expect(merged.videoFormats == ["I420", "Y444"])
        #expect(merged.encoder == "x264enc")
        #expect(merged.userID == "acct")
        #expect(update.merged(over: nil) == update)
    }

    @Test("cursor payloads decode the base64 image")
    func cursor() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let json = #"{"type":"cursor","data":{"serial":25542,"visible":true,"data":"\#(png.base64EncodedString())","xhot":4,"yhot":7,"cursor":false}}"#
        let message = try #require(ControlMessage.decode(json))
        guard case let .cursor(update) = message else {
            Issue.record("expected a cursor update, got \(message)")
            return
        }
        #expect(update.serial == 25542)
        #expect(update.visible)
        #expect(update.isWindowsCursor == false)
        #expect(update.imageData == png)
        #expect(update.hotSpotX == 4)
        #expect(update.hotSpotY == 7)
        #expect(update.usesDefaultPointer == false)
    }

    @Test("serial zero means the default pointer")
    func defaultPointer() throws {
        let message = try #require(ControlMessage.decode(
            #"{"type":"cursor","data":{"serial":0,"visible":false,"data":"","xhot":0,"yhot":0,"cursor":false}}"#
        ))
        guard case let .cursor(update) = message else {
            Issue.record("expected a cursor update")
            return
        }
        #expect(update.usesDefaultPointer)
        #expect(update.visible == false)
    }

    @Test("rtt echoes accept seconds and milliseconds")
    func rtt() throws {
        guard case let .rtt(milliseconds) = try #require(ControlMessage.decode(
            #"{"type":"rtt","data":{"timestamp":1729000000000}}"#
        )) else {
            Issue.record("expected rtt")
            return
        }
        #expect(milliseconds == 1_729_000_000_000)

        guard case let .rtt(seconds) = try #require(ControlMessage.decode(
            #"{"type":"rtt","data":{"timestamp":1729000000}}"#
        )) else {
            Issue.record("expected rtt")
            return
        }
        #expect(seconds == 1_729_000_000_000)
    }

    @Test("clipboard and disconnect")
    func clipboardAndDisconnect() throws {
        guard case let .clipboard(content) = try #require(ControlMessage.decode(
            #"{"type":"clipboard","data":{"content":"hello"}}"#
        )) else {
            Issue.record("expected clipboard")
            return
        }
        #expect(content == "hello")

        guard case let .forceDisconnect(message, initiator) = try #require(ControlMessage.decode(
            #"{"type":"force_disconnect","data":{"message":"kicked","initiatorId":"remote"}}"#
        )) else {
            Issue.record("expected force disconnect")
            return
        }
        #expect(message == "kicked")
        #expect(initiator == "remote")
    }

    @Test("garbage is rejected, unknown types are preserved")
    func robustness() {
        #expect(ControlMessage.decode("not json") == nil)
        #expect(ControlMessage.decode(#"{"type":"gamepad_ack","data":{}}"#) == .other(type: "gamepad_ack"))
    }
}
