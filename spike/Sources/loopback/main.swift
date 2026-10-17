import Foundation
import AppKit
@preconcurrency import WebRTC

// ShadowDesk Swift rewrite spike.
//
// Verifies, in-process, the exact client-side flow the ShadowDesk manager
// requires, without any network access to the real server:
//
//   1. answerer-only peer connection (server is always the offerer)
//   2. a VP8-only offer (like GStreamer's) is answered with a recvonly
//      m=video section -- without adding a transceiver by hand
//   3. server-created SCTP data channel "input" (the manager uses ids 1/3/5)
//   4. full ICE/DTLS/SCTP loopback with control text in both directions
//   5. Metal renderer availability for the video view
//
// Two non-obvious setups the spike pins down:
//   * RTCPeerConnectionFactory() (plain init) is H264-only on Apple platforms.
//     To get VP8 you must pass the default video factories explicitly
//     (see makeFactory()).
//   * A remote-created RTCDataChannel does not forward messages to the
//     RTCPeerConnection delegate until you set `dc.delegate` yourself.

print("== shadowift / libwebrtc spike ==")

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class Delegate: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let name: String
    var onCandidate: ((RTCIceCandidate) -> Void)?
    var onDataChannel: ((RTCDataChannel) -> Void)?
    var onMessage: ((RTCDataChannel, String) -> Void)?
    var onChannelOpen: ((RTCDataChannel) -> Void)?

    init(name: String) { self.name = name }

    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCPeerConnectionState) {
        print("[\(name)] pc state: \(stateName(stateChanged))")
    }
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onCandidate?(candidate)
    }
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[\(name)] remote-created data channel: label=\(dataChannel.label ?? "?") id=\(dataChannel.channelId)")
        onDataChannel?(dataChannel)
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func dataChannelDidChangeState(_ dc: RTCDataChannel) {
        print("[\(name)] dc \(dc.label ?? "?") state=\(dc.readyState.rawValue) id=\(dc.channelId)")
        if dc.readyState == .open { onChannelOpen?(dc) }
    }
    func dataChannel(_ dc: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        print("[\(name)] dc \(dc.label ?? "?") received: \(text)")
        onMessage?(dc, text)
    }
}

func stateName(_ s: RTCPeerConnectionState) -> String {
    switch s {
    case .new: return "new"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .disconnected: return "disconnected"
    case .failed: return "failed"
    case .closed: return "closed"
    @unknown default: return "?"
    }
}

// The factory MUST list VP8 explicitly, otherwise the SDP only carries H264.
func makeFactory() -> RTCPeerConnectionFactory {
    RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                             decoderFactory: RTCDefaultVideoDecoderFactory())
}

let factory = makeFactory()

func makePC(_ delegate: Delegate) -> RTCPeerConnection {
    let cfg = RTCConfiguration()
    cfg.sdpSemantics = .unifiedPlan
    cfg.bundlePolicy = .maxBundle
    cfg.rtcpMuxPolicy = .require
    cfg.iceServers = []
    let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    return factory.peerConnection(with: cfg, constraints: c, delegate: delegate)!
}

let rtcpConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

// Rewrite a libwebrtc offer into the VP8-only shape the manager's GStreamer
// pipeline actually sends.
func vp8Only(_ offer: String) -> String {
    var lines = offer.components(separatedBy: "\r\n")
    guard let mIndex = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return offer }
    let pts = lines[mIndex].split(separator: " ").dropFirst(3).map(String.init)
    var vp8: String?
    for line in lines where line.hasPrefix("a=rtpmap:") {
        let parts = line.dropFirst("a=rtpmap:".count).split(separator: " ")
        if parts.count >= 2, parts[1].hasPrefix("VP8/") { vp8 = String(parts[0]) }
    }
    guard let vp8pt = vp8 else { return offer }
    var rtx: String?
    for line in lines where line.hasPrefix("a=fmtp:") && line.contains("apt=\(vp8pt)") {
        rtx = String(line.dropFirst("a=fmtp:".count).split(separator: " ")[0])
    }
    let keep = Set([vp8pt, rtx].compactMap { $0 })
    lines[mIndex] = lines[mIndex].split(separator: " ").prefix(3).joined(separator: " ")
        + " " + pts.filter { keep.contains($0) }.joined(separator: " ")
    let attrPrefixes = ["a=rtpmap:", "a=rtcp-fb:", "a=fmtp:"]
    lines = lines.filter { line in
        for p in attrPrefixes where line.hasPrefix(p) {
            let pt = line.dropFirst(p.count).split(separator: " ").first.map(String.init) ?? ""
            return keep.contains(pt)
        }
        return true
    }
    return lines.joined(separator: "\r\n")
}

// ---------------------------------------------------------------------------
// 1. Offerer shaped like the manager (sendrecv video + SCTP "input")
// ---------------------------------------------------------------------------

let offererDelegate = Delegate(name: "offerer(server)")
let offerer = makePC(offererDelegate)
let videoInit = RTCRtpTransceiverInit()
videoInit.direction = .sendRecv
_ = offerer.addTransceiver(of: .video, init: videoInit)
let inputConfig = RTCDataChannelConfiguration()
inputConfig.isOrdered = true
let serverInput = offerer.dataChannel(forLabel: "input", configuration: inputConfig)!
serverInput.delegate = offererDelegate

// ---------------------------------------------------------------------------
// 2. Answerer = the client under test (no explicit transceiver)
// ---------------------------------------------------------------------------

let answererDelegate = Delegate(name: "answerer(client)")
let answerer = makePC(answererDelegate)

let gotInput = Flag()
let gotFromServer = Flag()
let gotFromClient = Flag()
let answerSDP = NSMutableString()
var inputFromServer: RTCDataChannel?

answererDelegate.onDataChannel = { dc in
    dc.delegate = answererDelegate // required for remote-created channels
    if dc.label == "input" { inputFromServer = dc; gotInput.set() }
}
offererDelegate.onMessage = { _, text in
    if text.hasPrefix("mm,") { gotFromClient.set() }   // client -> server
}
answererDelegate.onMessage = { _, text in
    if text.contains("config") { gotFromServer.set() } // server -> client
}

// ---------------------------------------------------------------------------
// 3. SDP + ICE exchange
// ---------------------------------------------------------------------------

let sem = DispatchSemaphore(value: 0)
offererDelegate.onCandidate = { c in answerer.add(c) { _ in } }
answererDelegate.onCandidate = { c in offerer.add(c) { _ in } }

offerer.offer(for: rtcpConstraints) { offer, err in
    guard let offer else { print("offer error: \(String(describing: err))"); sem.signal(); return }
    let slim = vp8Only(offer.sdp)
    print("VP8-only offer video line:",
          slim.components(separatedBy: "\r\n").first { $0.hasPrefix("m=video ") } ?? "?")
    offerer.setLocalDescription(offer) { _ in
        answerer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: slim)) { err in
            print("answerer setRemoteDescription error:", err?.localizedDescription ?? "none")
            answerer.answer(for: rtcpConstraints) { answer, err2 in
                print("answerer createAnswer error:", err2?.localizedDescription ?? "none")
                guard let answer else { sem.signal(); return }
                answerSDP.setString(answer.sdp)
                let video = answer.sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("m=video ") } ?? "?"
                let rtp = answer.sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=rtpmap") }
                print("answer video line:", video)
                print("answer rtpmap:", rtp.joined(separator: " | "))
                print("answer checks -> m=video:", answer.sdp.contains("m=video"),
                      "m=application:", answer.sdp.contains("m=application"),
                      "VP8:", answer.sdp.contains("VP8"),
                      "recvonly:", answer.sdp.contains("a=recvonly"),
                      "sctp-port:", answer.sdp.contains("sctp-port"))
                answerer.setLocalDescription(answer) { err3 in
                    print("answerer setLocalDescription error:", err3?.localizedDescription ?? "none")
                    offerer.setRemoteDescription(answer) { err4 in
                        print("offerer setRemoteDescription error:", err4?.localizedDescription ?? "none")
                        sem.signal()
                    }
                }
            }
        }
    }
}
_ = sem.wait(timeout: .now() + 10)

// ---------------------------------------------------------------------------
// 4. Wait for both channels to open, then exchange control messages
// ---------------------------------------------------------------------------

// Wait until both sides report open (SCTP state is per-association).
let deadline = Date().addingTimeInterval(15)
while Date() < deadline
    && !(inputFromServer?.readyState == .open && serverInput.readyState == .open) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
print("readyState client=\(inputFromServer?.readyState.rawValue ?? -1) server=\(serverInput.readyState.rawValue)")
RunLoop.current.run(until: Date().addingTimeInterval(1.0))

var clientSent = false
if let dc = inputFromServer, dc.readyState == .open {
    clientSent = dc.sendData(RTCDataBuffer(data: "mm,100,200".data(using: .utf8)!, isBinary: false))
}
let serverSent = serverInput.sendData(RTCDataBuffer(data: #"{"type":"config","data":{"resolution":"1920x1080"}}"#.data(using: .utf8)!, isBinary: false))
print("[client] sent mm,100,200 ->", clientSent, " [server] sent config ->", serverSent)

let wait = Date().addingTimeInterval(10)
while Date() < wait && !(gotFromClient.isSet && gotFromServer.isSet) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

print("--- results ---")
print("client got server 'input' channel:", gotInput.isSet)
print("server received client command :", gotFromClient.isSet)
print("client received server config  :", gotFromServer.isSet)
print("answer VP8 + recvonly video    :", answerSDP.contains("VP8") && answerSDP.contains("a=recvonly"))
print("Metal renderer available       :", RTCMTLNSVideoView.isMetalAvailable())

offerer.close()
answerer.close()
print("== spike done ==")
