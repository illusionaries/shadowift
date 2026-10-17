import Foundation

/// Snapshot of the manager's encoder configuration (`config` control message).
public struct ServerConfig: Sendable, Equatable, Decodable {
    public struct VideoSize: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
        /// Parses the agent's `"1920x1080"` notation.
        public init?(string: String) {
            let parts = string.lowercased().split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
                return nil
            }
            self.init(width: width, height: height)
        }
    }

    public var userID: String?
    public var framerate: Int?
    public var videoBitrate: Int?
    public var dynamicFramerate: Bool?
    public var videoFormat: String?
    /// Pixel formats the current encoder supports (e.g. `["I420", "Y444"]`).
    public var videoFormats: [String]?
    public var encoder: String?
    public var resolution: String?
    public var resolutions: [String]?
    public var adaptiveResolution: Bool?
    public var clipboardEnabled: Bool?
    public var audioEnabled: Bool?
    public var viewerCount: Int?

    public var resolutionSize: VideoSize? {
        resolution.flatMap(VideoSize.init(string:))
    }

    /// Layers a partial update over the last snapshot. The manager broadcasts
    /// configs that carry only the fields it feels like resending (e.g. just
    /// `resolution` in reply to a resize request), so fields absent from the
    /// latest message must keep their previous values instead of resetting.
    public func merged(over base: ServerConfig?) -> ServerConfig {
        guard let base else { return self }
        var result = self
        if result.userID == nil { result.userID = base.userID }
        if result.framerate == nil { result.framerate = base.framerate }
        if result.videoBitrate == nil { result.videoBitrate = base.videoBitrate }
        if result.dynamicFramerate == nil { result.dynamicFramerate = base.dynamicFramerate }
        if result.videoFormat == nil { result.videoFormat = base.videoFormat }
        if result.videoFormats == nil { result.videoFormats = base.videoFormats }
        if result.encoder == nil { result.encoder = base.encoder }
        if result.resolution == nil { result.resolution = base.resolution }
        if result.resolutions == nil { result.resolutions = base.resolutions }
        if result.adaptiveResolution == nil { result.adaptiveResolution = base.adaptiveResolution }
        if result.clipboardEnabled == nil { result.clipboardEnabled = base.clipboardEnabled }
        if result.audioEnabled == nil { result.audioEnabled = base.audioEnabled }
        if result.viewerCount == nil { result.viewerCount = base.viewerCount }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case framerate
        case videoBitrate = "video_bitrate"
        case dynamicFramerate = "enable_dynamic_framerate"
        case videoFormat = "video_format"
        case videoFormats = "video_formats"
        case encoder
        case resolution
        case resolutions
        case adaptiveResolution = "enableAdaptiveResolution"
        case clipboardEnabled = "enableClipboard"
        case audioEnabled = "enable_audio"
        case viewerCount = "curUsersNum"
    }
}

/// A `cursor` control message: the remote pointer shape.
public struct CursorUpdate: Sendable, Equatable, Decodable {
    public var serial: Int
    public var visible: Bool
    /// `true` when the payload is a CUR/ICO container, `false` for PNG.
    public var isWindowsCursor: Bool
    /// Decoded image bytes; empty for the "use the default arrow" case.
    public var imageData: Data
    public var hotSpotX: Int
    public var hotSpotY: Int

    private enum CodingKeys: String, CodingKey {
        case serial, visible, data, xhot, yhot, cursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serial = try container.decodeIfPresent(Int.self, forKey: .serial) ?? 0
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        isWindowsCursor = try container.decodeIfPresent(Bool.self, forKey: .cursor) ?? false
        let base64 = try container.decodeIfPresent(String.self, forKey: .data) ?? ""
        imageData = Data(base64Encoded: base64) ?? Data()
        hotSpotX = try container.decodeIfPresent(Int.self, forKey: .xhot) ?? 0
        hotSpotY = try container.decodeIfPresent(Int.self, forKey: .yhot) ?? 0
    }

    /// `serial == 0` means "the remote is using its default pointer".
    public var usesDefaultPointer: Bool { serial == 0 || imageData.isEmpty }
}

/// Every JSON message the manager pushes on the `input` data channel.
public enum ControlMessage: Sendable, Equatable {
    case serverConfig(ServerConfig)
    case clipboard(String)
    case cursor(CursorUpdate)
    case rtt(unixMilliseconds: Int64)
    case restart
    case refresh
    case log(String?)
    case forceDisconnect(message: String?, initiator: String?)
    case other(type: String)

    /// Decodes a raw text frame; returns `nil` when it is not valid JSON.
    public static func decode(_ text: String) -> ControlMessage? {
        guard let root = JSON.object(from: text), let type = root["type"] as? String else {
            return nil
        }
        let data = root["data"] as? [String: Any]

        switch type {
        case "config":
            guard let bytes = JSON.data(from: data),
                  let config = try? JSONDecoder().decode(ServerConfig.self, from: bytes)
            else { return .other(type: type) }
            return .serverConfig(config)

        case "clipboard":
            return .clipboard(data?["content"] as? String ?? "")

        case "cursor":
            guard let bytes = JSON.data(from: data),
                  let cursor = try? JSONDecoder().decode(CursorUpdate.self, from: bytes)
            else { return .other(type: type) }
            return .cursor(cursor)

        case "rtt":
            // The agent echoes the timestamp we sent. Accept numbers and
            // strings, and seconds as well as milliseconds.
            let raw = JSON.int64(from: data?["timestamp"]) ?? 0
            guard raw > 0 else { return .other(type: type) }
            let millis = raw < 100_000_000_000 ? raw * 1000 : raw
            return .rtt(unixMilliseconds: millis)

        case "restart":
            return .restart

        case "refresh":
            return .refresh

        case "log":
            return .log(data?["content"] as? String)

        case "force_disconnect":
            return .forceDisconnect(
                message: data?["message"] as? String,
                initiator: data?["initiatorId"] as? String
            )

        default:
            return .other(type: type)
        }
    }
}
