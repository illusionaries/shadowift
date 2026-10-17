import Foundation
@preconcurrency import WebRTC

// Codec capability probe.
//
// The trap this file documents: `RTCPeerConnectionFactory()` (the plain
// initializer) is documented as "default H264 video encoder/decoder factories"
// and its SDP offer only ever carries H264 + red/ulpfec. ShadowDesk's manager
// offers VP8 exclusively, so a client built on the plain initializer would
// negotiate nothing usable. Passing RTCDefaultVideoEncoderFactory /
// RTCDefaultVideoDecoderFactory explicitly restores VP8 (libvpx), VP9, AV1
// and H264 in one go.

print("== codec probe ==")

print("\nRTCDefaultVideoEncoderFactory.supportedCodecs():")
for codec in RTCDefaultVideoEncoderFactory.supportedCodecs() {
    print("  - \(codec.name) \(codec.parameters)")
}

func offerCodecs(_ factory: RTCPeerConnectionFactory) -> [String] {
    let cfg = RTCConfiguration()
    cfg.sdpSemantics = .unifiedPlan
    let pc = factory.peerConnection(
        with: cfg,
        constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
        delegate: nil)!
    let t = RTCRtpTransceiverInit()
    t.direction = .sendRecv
    _ = pc.addTransceiver(of: .video, init: t)
    let sem = DispatchSemaphore(value: 0)
    var out: [String] = []
    pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { offer, _ in
        out = offer!.sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=rtpmap") }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 10)
    pc.close()
    return out
}

print("\n--- offer with the plain initializer (RTCPeerConnectionFactory()) ---")
for line in offerCodecs(RTCPeerConnectionFactory()) { print("  \(line)") }

print("\n--- offer with explicit RTCDefaultVideo{Encoder,Decoder}Factory ---")
let explicit = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
for line in offerCodecs(explicit) { print("  \(line)") }
