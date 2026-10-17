@preconcurrency import WebRTC
import Foundation

/// One answerer-side WebRTC session.
///
/// The manager always sends the offer, so this wrapper only needs to accept it,
/// exchange ICE candidates, expose the server-created `input` data channel and
/// surface the decoded video track. Jitter buffering, NACK/PLI, VP8 decoding
/// and rendering are all handled by libwebrtc.
/// Sendable wrapper around a libwebrtc video track.
public struct VideoTrack: @unchecked Sendable {
    public let raw: RTCVideoTrack
    public init(_ raw: RTCVideoTrack) { self.raw = raw }
    public var isEnabled: Bool { raw.isEnabled }
    public func attach(_ renderer: RTCVideoRenderer) { raw.add(renderer) }
}

public final class PeerSession: NSObject, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var iceServers: [ICEServer]
        /// Only use TURN relays (the manager's `forceTurn` flag).
        public var forceRelay: Bool

        public init(iceServers: [ICEServer] = [], forceRelay: Bool = false) {
            self.iceServers = iceServers
            self.forceRelay = forceRelay
        }
    }

    public enum ConnectionState: String, Sendable {
        case new, connecting, connected, disconnected, failed, closed
    }

    public enum Event: @unchecked Sendable {
        case localCandidate(ICECandidate)
        case stateChanged(ConnectionState)
        /// The manager created the control channel and it is open.
        case controlChannelReady
        /// A text message arrived on the control channel.
        case controlMessage(String)
        /// The remote video track became available; attach a renderer to it.
        case videoTrack(VideoTrack)
    }

    public enum Error: Swift.Error, LocalizedError {
        case peerConnectionFailed
        case answerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .peerConnectionFailed: "Could not create the peer connection"
            case let .answerFailed(reason): "Could not answer the offer: \(reason)"
            }
        }
    }

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let peerConnection: RTCPeerConnection
    private let lock = NSLock()
    private var controlChannel: RTCDataChannel?
    /// The ObjC `RTCVideoTrack` wrapper owns the renderer adapters; if it is
    /// released, the sink is removed from the native track and frames stop.
    private var retainedTracks: [RTCVideoTrack] = []

    /// One libwebrtc factory per process is enough; creating it is expensive.
    /// `RTCDefaultVideoEncoderFactory` must be passed explicitly, otherwise
    /// the default configuration only knows H.264 and the VP8-only ShadowDesk
    /// offer cannot be answered. Decoding goes through
    /// ``ShadowDeskVideoDecoderFactory`` so H.264 4:4:4 (lossless color mode)
    /// works.
    private nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: ShadowDeskVideoDecoderFactory()
        )
    }()

    private static let mediaConstraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: nil
    )

    public init(configuration: Configuration) {
        (events, continuation) = AsyncStream.makeStream()

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.iceTransportPolicy = configuration.forceRelay ? .relay : .all
        config.iceServers = configuration.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }

        peerConnection = Self.factory.peerConnection(
            with: config,
            constraints: Self.mediaConstraints,
            delegate: nil
        )!
        super.init()
        peerConnection.delegate = self
    }

    /// Applies the manager's offer and returns the SDP answer to send back.
    public func accept(offer sdp: String) async throws -> String {
        let description = RTCSessionDescription(type: .offer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: Self.mediaConstraints) { answer, error in
                if let answer {
                    continuation.resume(returning: answer)
                } else {
                    continuation.resume(throwing: Error.answerFailed(error?.localizedDescription ?? "unknown"))
                }
            }
        }

        if ProcessInfo.processInfo.environment["SHADOWDESK_DEBUG_SDP"] != nil {
            FileHandle.standardError.write(Data("=== generated answer ===\n\(answer.sdp)\n=== end answer ===\n".utf8))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            peerConnection.setLocalDescription(answer) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return answer.sdp
    }

    public func add(candidate: ICECandidate) {
        // The manager closes trickling with an empty candidate; libwebrtc's
        // RTCIceCandidate rejects empty SDP strings.
        guard !candidate.candidate.isEmpty else { return }
        let ice = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
            sdpMid: candidate.sdpMid
        )
        peerConnection.add(ice) { _ in }
    }

    /// Sends one control command; returns `false` when the channel is not open.
    @discardableResult
    public func send(_ text: String) -> Bool {
        lock.lock()
        let channel = controlChannel
        lock.unlock()
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    public func close() {
        peerConnection.close()
        continuation.finish()
    }

    private func retain(_ track: RTCVideoTrack) {
        lock.lock()
        if !retainedTracks.contains(where: { $0 === track }) {
            retainedTracks.append(track)
        }
        lock.unlock()
    }

    /// All remote video tracks the peer connection currently knows about.
    public func videoTracks() -> [VideoTrack] {
        peerConnection.receivers.compactMap { $0.track as? RTCVideoTrack }.map(VideoTrack.init)
    }

    /// Coarse inbound video counters, sampled by the UI/status bar.
    public struct MediaStats: Sendable, Equatable {
        public var bytesReceived = 0
        public var packetsReceived = 0
        public var framesReceived = 0
        public var framesDecoded = 0
        public var keyFramesDecoded = 0
        public var frameWidth = 0
        public var frameHeight = 0
    }

    public func mediaStats() async -> MediaStats {
        await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                var stats = MediaStats()
                for entry in report.statistics.values where entry.type == "inbound-rtp" {
                    let values = entry.values
                    func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
                    stats.bytesReceived = max(stats.bytesReceived, int("bytesReceived") ?? 0)
                    stats.packetsReceived = max(stats.packetsReceived, int("packetsReceived") ?? 0)
                    stats.framesReceived = max(stats.framesReceived, int("framesReceived") ?? 0)
                    stats.framesDecoded = max(stats.framesDecoded, int("framesDecoded") ?? 0)
                    stats.keyFramesDecoded = max(stats.keyFramesDecoded, int("keyFramesDecoded") ?? 0)
                    stats.frameWidth = max(stats.frameWidth, int("frameWidth") ?? 0)
                    stats.frameHeight = max(stats.frameHeight, int("frameHeight") ?? 0)
                }
                continuation.resume(returning: stats)
            }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension PeerSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCPeerConnectionState) {
        continuation.yield(.stateChanged(Self.map(stateChanged)))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        continuation.yield(.localCandidate(ICECandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: UInt16(clamping: Int(candidate.sdpMLineIndex))
        )))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard dataChannel.label == "input" else { return } // file-* channels: later
        dataChannel.delegate = self
        lock.lock()
        controlChannel = dataChannel
        lock.unlock()
        if dataChannel.readyState == .open {
            continuation.yield(.controlChannelReady)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = receiver.track as? RTCVideoTrack {
            retain(track)
            continuation.yield(.videoTrack(VideoTrack(track)))
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            retain(track)
            continuation.yield(.videoTrack(VideoTrack(track)))
        }
    }

    // Unused delegate requirements.
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    private static func map(_ state: RTCPeerConnectionState) -> ConnectionState {
        switch state {
        case .new: .new
        case .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        @unknown default: .new
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension PeerSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == "input", dataChannel.readyState == .open else { return }
        continuation.yield(.controlChannelReady)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        continuation.yield(.controlMessage(text))
    }
}
