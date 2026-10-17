@preconcurrency import WebRTC
import Foundation

/// Coordinates one ShadowDesk connection: login → signalling → WebRTC →
/// control channel. Everything the UI needs is surfaced as an ``Event``.
public actor ShadowDeskClient {
    public struct Configuration: Sendable {
        public var server: URL
        public var user: String
        public var password: String
        /// Reported to the manager in `hello`; it may adjust the encoder for it.
        public var os: String
        public var browser: String

        public init(
            server: URL,
            user: String,
            password: String,
            os: String = "macOS 14.5",
            browser: String = "Chrome"
        ) {
            self.server = server
            self.user = user
            self.password = password
            self.os = os
            self.browser = browser
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case signingIn
        case connecting
        case connected
        case closed
    }

    public enum Event: @unchecked Sendable {
        case stateChanged(State)
        case log(String)
        case serverConfig(ServerConfig)
        case clipboard(String)
        case cursor(CursorUpdate)
        /// Control channel round trip time in milliseconds.
        case latency(Int)
        case videoTrack(VideoTrack)
        case controlChannelReady
        /// The session is over; `reason` is human readable.
        case ended(reason: String?)
    }

    private let configuration: Configuration
    private let authClient = AuthClient()
    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private var auth: AuthSession?
    private var signaling: SignalingClient?
    private var peer: PeerSession?
    private var pumps: [Task<Void, Never>] = []
    private var heartbeat: Task<Void, Never>?

    public private(set) var state: State = .idle
    public private(set) var serverConfig: ServerConfig?

    public init(configuration: Configuration) {
        self.configuration = configuration
        (stream, continuation) = AsyncStream.makeStream()
    }

    public func events() -> AsyncStream<Event> { stream }

    /// Runs the whole connection setup. Throws when login or signalling fails.
    public func start() async throws {
        guard state == .idle || state == .closed else { return }
        setState(.signingIn)
        do {
            let auth = try await authClient.login(
                to: configuration.server,
                user: configuration.user,
                password: configuration.password
            )
            self.auth = auth
            log("signed in as \(auth.user) (clientId \(auth.clientID.prefix(16))…)")

            setState(.connecting)
            let signaling = SignalingClient(
                session: auth,
                os: configuration.os,
                browser: configuration.browser
            )
            self.signaling = signaling
            try await signaling.connect()

            let events = await signaling.events
            pumps.append(Task { [weak self] in
                for await event in events {
                    await self?.handle(signaling: event)
                }
            })
        } catch {
            setState(.closed)
            throw error
        }
    }

    /// Tears the session down and logs out (which also frees the remote worker).
    public func stop() async {
        heartbeat?.cancel()
        heartbeat = nil
        for task in pumps { task.cancel() }
        pumps.removeAll()
        peer?.close()
        peer = nil
        if let signaling {
            await signaling.close()
        }
        signaling = nil
        if let auth {
            await authClient.logout(auth)
        }
        auth = nil
        setState(.closed)
    }

    /// Sends a control command when the control channel is open.
    @discardableResult
    public func send(_ command: ControlCommand) -> Bool {
        peer?.send(command.encoded) ?? false
    }

    /// Coarse inbound video counters (nil before the peer exists).
    public func mediaStats() async -> PeerSession.MediaStats? {
        await peer?.mediaStats()
    }

    /// Remote video tracks known to the peer connection.
    public func videoTracks() -> [VideoTrack] {
        peer?.videoTracks() ?? []
    }

    // MARK: - Event routing

    private func handle(signaling event: SignalingEvent) async {
        switch event {
        case let .sessionAssigned(info):
            log("session assigned (ip=\(info.ip ?? "?"), forceTurn=\(info.forceTurn ?? false), iceServers=\(info.iceServers.count))")
            let peer = PeerSession(configuration: .init(
                iceServers: info.iceServers,
                forceRelay: info.forceTurn ?? false
            ))
            self.peer = peer
            let events = peer.events
            pumps.append(Task { [weak self] in
                for await event in events {
                    await self?.handle(peer: event)
                }
            })

        case let .offer(sdp):
            guard let peer else { return }
            if ProcessInfo.processInfo.environment["SHADOWDESK_DEBUG_SDP"] != nil {
                FileHandle.standardError.write(Data("=== offer sdp ===\n\(sdp)\n=== end offer ===\n".utf8))
            }
            do {
                let answer = try await peer.accept(offer: sdp)
                try await signaling?.sendAnswer(answer)
                log("SDP answer sent")
            } catch {
                end(reason: "could not answer the offer: \(error.localizedDescription)")
            }

        case let .remoteCandidate(candidate):
            peer?.add(candidate: candidate)

        case let .stateChanged(managerState):
            log("manager state: \(managerState)")

        case .unauthorized:
            end(reason: "session unauthorized — please sign in again")

        case .licenseExpired:
            end(reason: "license expired")

        case let .serverDisconnected(reason):
            end(reason: reason ?? "the server closed the session")

        case let .closed(reason):
            if state != .closed {
                end(reason: reason)
            }
        }
    }

    private func handle(peer event: PeerSession.Event) async {
        switch event {
        case let .localCandidate(candidate):
            try? await signaling?.send(candidate: candidate)

        case let .stateChanged(connectionState):
            switch connectionState {
            case .connected:
                setState(.connected)
            case .failed:
                end(reason: "peer connection failed")
            case .disconnected:
                log("peer connection disconnected")
            case .closed:
                if state == .connected { setState(.closed) }
            default:
                break
            }

        case .controlChannelReady:
            log("control channel open — the desktop is interactive")
            continuation.yield(.controlChannelReady)
            heartbeat?.cancel()
            heartbeat = heartbeatTask()
            send(.recover)
            send(.clipboardCapability(.enabled))

        case let .controlMessage(text):
            handle(control: text)

        case let .videoTrack(track):
            continuation.yield(.videoTrack(track))
        }
    }

    private func handle(control text: String) {
        guard let message = ControlMessage.decode(text) else { return }
        switch message {
        case let .serverConfig(config):
            serverConfig = config
            if let size = config.resolutionSize {
                log("server config: \(size.width)x\(size.height) \(config.videoFormat ?? "") \(config.encoder ?? "")")
            }
            continuation.yield(.serverConfig(config))

        case let .clipboard(content):
            continuation.yield(.clipboard(content))

        case let .cursor(update):
            continuation.yield(.cursor(update))

        case let .rtt(unixMilliseconds):
            let latency = Int(Date().timeIntervalSince1970 * 1000) - Int(unixMilliseconds)
            continuation.yield(.latency(max(0, latency)))

        case let .forceDisconnect(message, initiator):
            let who = (initiator == "remote") ? "the remote side" : "another viewer"
            end(reason: message ?? "disconnected by \(who)")

        case .restart:
            log("the server restarted the pipeline")

        case .refresh:
            log("the server asked for a refresh")

        case let .log(content):
            if let content { log(content) }

        case let .other(type):
            log("control message: \(type)")
        }
    }

    // MARK: - Plumbing

    private func heartbeatTask() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                await self?.send(.rtt(unixMilliseconds: now))
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        continuation.yield(.stateChanged(newState))
    }

    private func log(_ message: String) {
        continuation.yield(.log(message))
    }

    private func end(reason: String?) {
        heartbeat?.cancel()
        heartbeat = nil
        setState(.closed)
        continuation.yield(.ended(reason: reason))
    }
}
