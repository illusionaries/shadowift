import Foundation

// MARK: - Wire models

/// One entry of the manager's `iceServers` array.
public struct ICEServer: Sendable, Codable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// File transfer channel metadata (unused for now, kept for logging).
public struct FileSession: Sendable, Codable, Equatable {
    public var id: String
    public var strategy: Int
}

/// Payload of the manager's `session ok` message.
public struct SessionInfo: Sendable, Equatable {
    public var connectionID: String?
    public var ip: String?
    public var forceTurn: Bool?
    public var iceServers: [ICEServer]
    public var fileSession: FileSession?
    public var os: String?
    public var browserInfo: String?
    public var isAudio: Bool?
}

/// A trickled ICE candidate, in both directions.
public struct ICECandidate: Sendable, Equatable {
    public var candidate: String
    public var sdpMid: String?
    public var sdpMLineIndex: UInt16?

    public init(candidate: String, sdpMid: String? = nil, sdpMLineIndex: UInt16? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

/// Everything the signalling socket can hand to the session.
public enum SignalingEvent: Sendable {
    case sessionAssigned(SessionInfo)
    case stateChanged(String)
    case offer(sdp: String)
    case remoteCandidate(ICECandidate)
    case unauthorized
    case licenseExpired
    case serverDisconnected(reason: String?)
    case closed(reason: String?)
}

// MARK: - Decoding

extension SessionInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case connectionID = "connectionId"
        case ip, forceTurn, iceServers, fileSession, os, browserInfo, isAudio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionID = try container.decodeIfPresent(String.self, forKey: .connectionID)
        ip = try container.decodeIfPresent(String.self, forKey: .ip)
        forceTurn = try container.decodeIfPresent(Bool.self, forKey: .forceTurn)
        iceServers = try container.decodeIfPresent([ICEServer].self, forKey: .iceServers) ?? []
        fileSession = try container.decodeIfPresent(FileSession.self, forKey: .fileSession)
        os = try container.decodeIfPresent(String.self, forKey: .os)
        browserInfo = try container.decodeIfPresent(String.self, forKey: .browserInfo)
        isAudio = try container.decodeIfPresent(Bool.self, forKey: .isAudio)
    }
}

/// Helpers shared by the signalling and control channel decoders.
enum JSON {
    /// Turns a `String` into a JSON object dictionary.
    static func object(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    /// Re-encodes a nested JSON value so it can be decoded with `JSONDecoder`.
    static func data(from value: Any?) -> Data? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    static func string(from value: Any?) -> String? {
        value as? String
    }

    static func int(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            return Int(text)
        default:
            return nil
        }
    }

    static func int64(from value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let text as String:
            return Int64(text)
        default:
            return nil
        }
    }

    static func bool(from value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}
