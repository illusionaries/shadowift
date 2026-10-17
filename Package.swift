// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Minimal static FFmpeg built by Scripts/build-ffmpeg.sh (decode-only H.264,
// macOS 14 deployment target, no external dependencies).
let ffmpegPrefix = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/FFmpeg")
    .path
if !FileManager.default.fileExists(atPath: "\(ffmpegPrefix)/lib/libavcodec.a") {
    fputs("warning: Vendor/FFmpeg missing — run ./Scripts/build-ffmpeg.sh first\n", stderr)
}

let package = Package(
    name: "ShadowDesk",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ShadowDeskKit", targets: ["ShadowDeskKit"]),
        .executable(name: "ShadowDesk", targets: ["ShadowDesk"]),
        .executable(name: "shadowprobe", targets: ["shadowprobe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0"),
    ],
    targets: [
        .target(
            name: "FFmpegSupport",
            path: "Sources/FFmpegSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "\(ffmpegPrefix)/lib/libavcodec.a",
                    "\(ffmpegPrefix)/lib/libavutil.a",
                ]),
            ]
        ),
        .target(
            name: "ShadowDeskKit",
            dependencies: [
                "FFmpegSupport",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .executableTarget(
            name: "ShadowDesk",
            dependencies: [
                "ShadowDeskKit",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/ShadowDeskMac"
        ),
        .executableTarget(
            name: "shadowprobe",
            dependencies: ["ShadowDeskKit"]
        ),
        .testTarget(
            name: "ShadowDeskKitTests",
            dependencies: ["ShadowDeskKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
