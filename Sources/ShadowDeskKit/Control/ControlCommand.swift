import Foundation

/// A command sent to the remote agent over the SCTP control channel.
///
/// The wire format is a small comma separated language; `encoded` is the exact
/// string to put on the channel. Keep the cases in sync with the agent's
/// parser (see `docs/PROTOCOL.md` in the server repository).
public enum ControlCommand: Equatable, Sendable {
    /// Absolute pointer position, in video pixels.
    case mouseMove(x: Int, y: Int)
    /// Relative pointer movement plus the accumulated absolute position.
    case mouseRelative(dx: Int, dy: Int, x: Int, y: Int)
    case mouseDown(MouseButton)
    case mouseUp(MouseButton)
    /// One wheel notch, `up == true` means the page scrolls up.
    case wheel(up: Bool)
    /// Trackpad style smooth scrolling, in pixels.
    case trackpadScroll(delta: Int)
    case keyDown(String)
    case keyUp(String)
    case keyPress(String)
    /// Ask the agent to capture `width x height`; `adaptive` lets it follow
    /// the client window.
    case resolution(width: Int, height: Int, adaptive: Bool)
    case framerate(Int)
    case dynamicFramerate(Bool)
    case videoBitrate(kbps: Int)
    case videoFormat(String)
    case volume(sessionID: String, percent: Int)
    case clipboard(String)
    case clipboardCapability(ClipboardCapability)
    /// Latency probe; the agent echoes the timestamp back.
    case rtt(unixMilliseconds: Int64)
    /// Force the encoder to emit a keyframe.
    case recover
    case disconnect(clientID: String)
    case debugConfig(element: String, property: String, value: String)

    public enum MouseButton: Int, Sendable {
        case left = 0, middle = 1, right = 2
    }

    public enum ClipboardCapability: String, Sendable {
        case enabled = "enable"
        case blocked
        case unavailable
        case undefined
    }

    public var encoded: String {
        switch self {
        case let .mouseMove(x, y):
            return "mm,\(x),\(y)"
        case let .mouseRelative(dx, dy, x, y):
            return "mmr,\(dx),\(dy),\(x),\(y)"
        case let .mouseDown(button):
            return "md,\(button.rawValue)"
        case let .mouseUp(button):
            return "mu,\(button.rawValue)"
        case let .wheel(up):
            return up ? "mw,1" : "mw,0"
        case let .trackpadScroll(delta):
            return "mts,\(delta)"
        case let .keyDown(key):
            return "kd,\(key)"
        case let .keyUp(key):
            return "ku,\(key)"
        case let .keyPress(key):
            return "kp,\(key)"
        case let .resolution(width, height, adaptive):
            return "resolution,\(width)x\(height),\(adaptive)"
        case let .framerate(value):
            return "framerate,\(value)"
        case let .dynamicFramerate(on):
            return "enable_dynamic_framerate,\(on)"
        case let .videoBitrate(kbps):
            return "video_bitrate,\(kbps)"
        case let .videoFormat(format):
            return "video_format,\(format)"
        case let .volume(sessionID, percent):
            return "volume_control,\(sessionID),\(percent)"
        case let .clipboard(text):
            // The agent's channel is line based, so newlines never survive.
            let flattened = text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return "clipboard,\(flattened)"
        case let .clipboardCapability(state):
            return "config_clipboard,\(state.rawValue),false"
        case let .rtt(unixMilliseconds):
            return "rtt,\(unixMilliseconds)"
        case .recover:
            return "recover"
        case let .disconnect(clientID):
            return "disconnect,\(clientID)"
        case let .debugConfig(element, property, value):
            return "debug_config,\(element),\(property),\(value)"
        }
    }
}

extension ControlCommand: CustomStringConvertible {
    public var description: String { encoded }
}
