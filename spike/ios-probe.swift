import Foundation
import WebRTC

// iOS/iPadOS availability probe: the same core classes and the UIKit Metal
// renderer must exist in the iOS slice of the xcframework.
func probe() {
    let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())
    let cfg = RTCConfiguration(); cfg.sdpSemantics = .unifiedPlan
    cfg.bundlePolicy = .maxBundle
    let pc = factory.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)!
    let t = RTCRtpTransceiverInit(); t.direction = .recvOnly
    _ = pc.addTransceiver(of: .video, init: t)
    let dc = pc.dataChannel(forLabel: "input", configuration: RTCDataChannelConfiguration())!
    dc.delegate = nil
    let view = RTCMTLVideoView(frame: .zero)
    view.videoContentMode = .scaleAspectFit

    print(pc, dc, view, RTCCameraVideoCapturer.self)
}
