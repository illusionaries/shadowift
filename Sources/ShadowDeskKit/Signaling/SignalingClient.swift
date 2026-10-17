import Foundation

/// The signalling WebSocket: `wss://<host>/<base>/api/ws`.
///
/// The manager is always the SDP offerer. The client registers with `hello`,
/// answers the offer, and trickles ICE in both directions. Server messages
/// arrive as an `AsyncStream` of ``SignalingEvent``.
public actor SignalingClient {
    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    public enum Error: Swift.Error, LocalizedError {
        case notConnected
        case badMessage(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: "Signalling connection is not open"
            case let .badMessage(text): "Malformed signalling message: \(text.prefix(120))"
            }
        }
    }

    private let session: AuthSession
    private let os: String
    private let browser: String
    private let origin: String?

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let stream: AsyncStream<SignalingEvent>
    private let continuation: AsyncStream<SignalingEvent>.Continuation

    /// The session uuid the manager assigned with `session ok`.
    public private(set) var sessionID: String?

    public init(
        session: AuthSession,
        os: String = "macOS 14.5",
        browser: String = "Chrome",
        origin: String? = nil
    ) {
        self.session = session
        self.os = os
        self.browser = browser
        self.origin = origin
        (stream, continuation) = AsyncStream.makeStream()
    }

    /// Events pushed by the manager; ends when the socket closes.
    public var events: AsyncStream<SignalingEvent> { stream }

    /// Opens the socket and registers the session with `hello`.
    public func connect() async throws {
        var request = URLRequest(url: session.webSocketURL)
        request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let task = Self.urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        try await sendHello()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    /// Sends the SDP answer produced by the peer session.
    public func sendAnswer(_ sdp: String) async throws {
        try await sendJSON([
            "type": "sdp",
            "data": ["type": "answer", "sdp": sdp],
        ])
    }

    /// Trickles one local ICE candidate to the manager.
    public func send(candidate: ICECandidate) async throws {
        var data: [String: Any] = ["candidate": candidate.candidate]
        data["sdpMid"] = candidate.sdpMid ?? "0"
        data["sdpMLineIndex"] = Int(candidate.sdpMLineIndex ?? 0)
        data["usernameFragment"] = NSNull()
        try await sendJSON(["type": "ice", "data": data])
    }

    public func close() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation.finish()
    }

    // MARK: - Private

    private func sendHello() async throws {
        try await sendJSON([
            "type": "hello",
            "data": [
                "clientId": session.clientID,
                "connectionId": "",
                "isAudio": false,
                "os": os,
                "browserInfo": browser,
            ],
            "browserInfo": browser,
        ])
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let task else { throw Error.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    handle(text)
                case let .data(data):
                    handle(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                continuation.yield(.closed(reason: error.localizedDescription))
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let root = JSON.object(from: text), let type = root["type"] as? String else {
            continuation.yield(.closed(reason: "malformed signalling message"))
            return
        }
        if let uuid = root["uuid"] as? String, !uuid.isEmpty {
            sessionID = uuid
        }
        let payload = JSON.data(from: root["data"])

        switch type {
        case "session ok":
            if let payload, let info = try? JSONDecoder().decode(SessionInfo.self, from: payload) {
                continuation.yield(.sessionAssigned(info))
            }
        case "session_state_update":
            if let payload,
               let state = try? JSONDecoder().decode(StatePayload.self, from: payload) {
                continuation.yield(.stateChanged(state.state))
            }
        case "sdp":
            if let payload, let sdp = try? JSONDecoder().decode(SDPPayload.self, from: payload),
               sdp.type == "offer" {
                continuation.yield(.offer(sdp: sdp.sdp))
            }
        case "ice":
            if let payload, let ice = try? JSONDecoder().decode(ICEPayload.self, from: payload) {
                continuation.yield(.remoteCandidate(ICECandidate(
                    candidate: ice.candidate,
                    sdpMid: ice.sdpMid,
                    sdpMLineIndex: ice.sdpMLineIndex
                )))
            }
        case "unauthorized":
            continuation.yield(.unauthorized)
        case "license":
            continuation.yield(.licenseExpired)
        case "disconnect":
            let reason = (root["data"] as? [String: Any])?["message"] as? String
            continuation.yield(.serverDisconnected(reason: reason))
        default:
            break // mouse/keyboard notifications and friends are noise
        }
    }

    private struct StatePayload: Decodable { let state: String }
    private struct SDPPayload: Decodable { let type: String; let sdp: String }
    private struct ICEPayload: Decodable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: UInt16?
    }
}
