import Foundation
import Testing

@testable import ShadowDeskKit

@Suite("Control command encoding")
struct ControlCommandTests {
    @Test("pointer and button commands")
    func pointerCommands() {
        #expect(ControlCommand.mouseMove(x: 1280, y: 720).encoded == "mm,1280,720")
        #expect(ControlCommand.mouseRelative(dx: -3, dy: 4, x: 10, y: 20).encoded == "mmr,-3,4,10,20")
        #expect(ControlCommand.mouseDown(.left).encoded == "md,0")
        #expect(ControlCommand.mouseUp(.middle).encoded == "mu,1")
        #expect(ControlCommand.mouseDown(.right).encoded == "md,2")
        #expect(ControlCommand.wheel(up: true).encoded == "mw,1")
        #expect(ControlCommand.wheel(up: false).encoded == "mw,0")
        #expect(ControlCommand.trackpadScroll(delta: -42).encoded == "mts,-42")
    }

    @Test("keyboard commands carry the browser key name verbatim")
    func keyboardCommands() {
        #expect(ControlCommand.keyDown("a").encoded == "kd,a")
        #expect(ControlCommand.keyUp("A").encoded == "ku,A")
        #expect(ControlCommand.keyPress("ArrowLeft").encoded == "kp,ArrowLeft")
        #expect(ControlCommand.keyDown("Control").encoded == "kd,Control")
    }

    @Test("video negotiation commands")
    func videoCommands() {
        #expect(ControlCommand.resolution(width: 1454, height: 864, adaptive: true).encoded
            == "resolution,1454x864,true")
        #expect(ControlCommand.framerate(30).encoded == "framerate,30")
        #expect(ControlCommand.dynamicFramerate(false).encoded == "enable_dynamic_framerate,false")
        #expect(ControlCommand.videoBitrate(kbps: 16000).encoded == "video_bitrate,16000")
        #expect(ControlCommand.videoFormat("I420").encoded == "video_format,I420")
        #expect(ControlCommand.volume(sessionID: "uuid-1", percent: 80).encoded == "volume_control,uuid-1,80")
    }

    @Test("clipboard is flattened onto one line")
    func clipboardFlattening() {
        #expect(ControlCommand.clipboard("hello").encoded == "clipboard,hello")
        #expect(ControlCommand.clipboard("a\nb\r\nc").encoded == "clipboard,a b c")
        #expect(ControlCommand.clipboardCapability(.enabled).encoded == "config_clipboard,enable,false")
        #expect(ControlCommand.clipboardCapability(.blocked).encoded == "config_clipboard,blocked,false")
    }

    @Test("misc commands")
    func miscCommands() {
        #expect(ControlCommand.rtt(unixMilliseconds: 1_729_000_000_000).encoded == "rtt,1729000000000")
        #expect(ControlCommand.recover.encoded == "recover")
        #expect(ControlCommand.disconnect(clientID: "abc").encoded == "disconnect,abc")
        #expect(ControlCommand.debugConfig(element: "vp8enc", property: "target-bitrate", value: "1")
            .encoded == "debug_config,vp8enc,target-bitrate,1")
    }
}
