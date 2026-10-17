# shadowift spike — libwebrtc 可行性验证

本目录是一个**可运行、可复现**的最小原型，证明 ShadowDesk 客户端
可以用 Swift + libwebrtc 实现。它**不连真实服务器**，在单进程内用 libwebrtc 自己扮演
“服务端 offerer”，让“Swift 客户端 answerer”走完整个链路。

## 包含什么

| 目标 | 说明 |
|---|---|
| `loopback` | 进程内复刻服务端行为：生成与服务端同构的 offer（sendrecv 视频 + SCTP `input` 通道），裁剪成**服务端实际下发的 VP8-only 形态**，交给按客户端方式构造的 answerer；完成 SDP/ICE/DTLS/SCTP 建链，并双向收发控制文本（`mm,100,200` 与 config JSON） |
| `codecprobe` | 对比 `RTCPeerConnectionFactory()` 与显式 `RTCDefaultVideo{Encoder,Decoder}Factory` 的编解码器清单——**前者只有 H264，后者才有 VP8** |
| `ios-probe.swift` | 用 iPhoneOS SDK 对 iOS 切片做 Swift 6 类型检查（`RTCMTLVideoView`、`RTCDataChannel`、`RTCRtpTransceiver` 等） |
| `output/` | 上述程序的原始输出 |

## 已验证的结论

- 纯 answerer 应答：`setRemoteDescription` → `createAnswer`，**不需要**像 pion 那样手动加
  recvonly transceiver；answer 自动包含 `m=video`（recvonly VP8）与 `m=application`（SCTP）。
- 服务端创建的 `input` 数据通道通过 `didOpenDataChannel` 回调到达，双向文本可收发。
- macOS `RTCMTLNSVideoView` 存在且 Metal 可用；iOS `RTCMTLVideoView` 在 iOS 切片中存在。
- 两个必须注意的坑：
  1. `RTCPeerConnectionFactory()`（裸初始化）**只有 H264**，必须显式传默认视频工厂才有 VP8；
  2. 服务端创建的 `RTCDataChannel` 必须自己设 `dc.delegate`，否则收不到消息。

## 运行

```bash
./run.sh
```

首次运行会通过 SPM 下载预编译 libwebrtc（~45 MB）。脚本里设置了
`GIT_SSL_NO_VERIFY=1`（本机 git 经 TLS 拦截镜像，直连 github.com 时可去掉），
并用 `DYLD_FRAMEWORK_PATH` 解决命令行程序找不到 `@rpath/WebRTC.framework` 的问题
（正式的 `.app` 由 Xcode 自动 embed，无此问题）。

iOS 类型检查：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios17.0 -sdk "$SDK" \
  -F .build/artifacts/webrtc/WebRTC/WebRTC.xcframework/ios-arm64 -swift-version 6 ios-probe.swift
```

## 环境

- macOS 27.0.1（Apple M2）、Xcode 27、Swift 6.4
- `stasel/WebRTC` M155（libwebrtc 官方源码构建；含 macOS / iOS / iOS 模拟器 / Mac Catalyst 切片）

## 不覆盖什么

真实服务器连接（登录/信令/TURN/真实 VP8 码流）、视频渲染成图、iOS 真机构建。
这些已由主仓库的正式实现覆盖；本 spike 的目的是提前消除 RTC 层的不确定性。
