// swift-tools-version: 6.0
//
// shadowift spike: proof that the ShadowDesk client can be rebuilt in Swift.
//
// Two tiny executables, both purely local (no ShadowDesk server needed):
//
//   loopback   - replays the exact client-side WebRTC flow inside one process:
//                a server-shaped offerer (VP8-only video + "input" SCTP channel)
//                talks to an answerer built the way the Swift client would be.
//                Verifies SDP, ICE, DTLS, SCTP and bidirectional control text.
//
//   codecprobe - shows which codecs the two factory flavours advertise. This is
//                the trap: RTCPeerConnectionFactory() alone is H264-only, so a
//                VP8-only ShadowDesk offer cannot be answered unless the default
//                video factories are passed explicitly.
//
// The WebRTC dependency is the community prebuilt libwebrtc binary package
// (stasel/WebRTC M155). It contains macOS (arm64+x86_64), iOS device, iOS
// simulator and Mac Catalyst slices in one xcframework.

import PackageDescription

let package = Package(
    name: "shadowift-spike",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "loopback",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")],
            path: "Sources/loopback",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "codecprobe",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")],
            path: "Sources/codecprobe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
