# shadowift — ShadowDesk 的 Swift 原生客户端

ShadowDesk 远程桌面的 Swift + libwebrtc 原生客户端。**macOS 版本已可日常使用**；
核心 Kit 与平台无关，iOS/iPadOS 可复用同一套。

```
shadowift/
├── Sources/
│   ├── ShadowDeskKit/     # 跨平台核心：登录、信令、WebRTC、控制命令、光标、历史、钥匙串
│   ├── ShadowDeskMac/     # macOS App（SwiftUI + AppKit + 自研 YUVMetalView 渲染器）
│   ├── FFmpegSupport/     # FFmpeg C 头文件桥（libavcodec/libavutil，H.264 解码用）
│   └── shadowprobe/       # 无头自检 CLI（登录→解码→可选导出 PNG）
├── Tests/ShadowDeskKitTests/
├── Scripts/make-app.sh    # 组装 dist/ShadowDesk.app（图标、WebRTC.framework、rpath、签名）
├── Scripts/build-ffmpeg.sh# 编译精简静态 FFmpeg（仅 H.264 解码，输出到 Vendor/FFmpeg）
├── Scripts/make-icon.swift# 生成 AppIcon.icns（渐变圆角 + display 符号，10 个尺寸）
└── spike/                 # 可行性验证原型（libwebrtc 回环、编解码器探测、iOS API 探测）
```

## 功能

已实现并**用真实服务实测通过**：

- 登录 / 登出 / 重置管线（`/api/login` 302 + cookie、失败详情解析）
- 信令 WebSocket（`hello` / offer-answer / trickle ICE / 会话状态 / 掉线事件）
- WebRTC（libwebrtc M155，VP8 接收、SCTP `input` 控制通道、`forceTurn` 走 TURN）
- H.264 软解：FFmpeg（libavcodec）经由自定义 `RTCVideoDecoder` 接入 libwebrtc，
  支持 High 4:4:4 Predictive（VideoToolbox 只到 4:2:0），见下文「无损色彩模式」
- 控制通道：`config` / `cursor` / `clipboard` / `rtt` 解析，19 条控制命令编码，RTT 心跳
- 剪贴板双向同步：远端推送 → 写入本机 `NSPasteboard`；本机变化 → 轮询 `changeCount` 后发送
  `clipboard,<text>`（换行按协议替换为空格）；View 菜单可关闭自动同步，⌥⌘V 手动推送
  - macOS **没有**剪贴板变更通知 API（AppKit 官方立场就是轮询），见 `PasteboardBridge`：
    前台 0.5 s / 后台 2 s 自适应轮询，所有读写串行在专用队列（`NSPasteboard` 非线程安全，
    读取可能阻塞在主线程外做），带 `org.nspasteboard.ConcealedType`/`TransientType` 的
    密码类内容不外发
- 视频渲染：自研 `YUVMetalView`（Metal 直渲 Y/U/V 平面，4:2:0 双线性色度上采样、
  4:4:4 色度 1:1 不降采样），Retina 原生分辨率
- 指针：绝对坐标模型（不抓取、不搬动本地光标），远端光标素材绘制，进入画面自动接管
- 键盘：浏览器 `KeyboardEvent.key` 名映射（含小键盘 / 功能键 / 修饰键），`Ctrl+Opt+Shift+键` 直接触发本地命令
- 自适应分辨率：窗口变化 → `resolution,WxH,true`，±2 px 容忍
- **无损色彩模式**（View 菜单，服务端提供 Y444 时出现）：见下文「无损色彩模式」
- **1:1 原生像素模式**（View 菜单 / ⌥⌘1）：请求"窗口点数 × Retina 缩放"的分辨率，
  让视频像素与屏幕物理像素一一对应，取消 GPU 放大。注意服务端虚拟显示上限约
  **1918×1078**，超出时会被按比例缩小，此时状态栏显示橙色的 `1:1 capped`
- 账号历史（`~/Library/Application Support/shadowdesk/history.json`）
  与 macOS 钥匙串（`shadowdesk:<server>`）记住密码

状态栏实时显示分辨率 / FPS / 码率 / 控制通道 RTT。

尚未实现（后续）：自动重连退避、全屏快捷键冲突细化、多显示器、
音频与文件传输、iOS/iPadOS 前端。

## 构建与运行

```bash
# 首次拉取预编译 libwebrtc（~45 MB）
GIT_SSL_NO_VERIFY=1 swift package resolve      # 直连 github 时可省略 GIT_SSL_NO_VERIFY

# 首次构建精简 FFmpeg（静态 libavcodec/libavutil，仅 H.264 解码，~2 分钟）
./Scripts/build-ffmpeg.sh

swift build
swift test

# 打包并运行 macOS App（Scripts/AppIcon.icns 已随仓库提供）
./Scripts/make-app.sh
open dist/ShadowDesk.app

# 需要重新生成图标时：
swift Scripts/make-icon.swift /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Scripts/AppIcon.icns
open dist/ShadowDesk.app --args --auto         # 用历史账号 + 钥匙串直接连接
```

无头自检（不打开窗口，验证协议与解码链路）：

```bash
BIN=$(swift build --show-bin-path)
DYLD_FRAMEWORK_PATH=$BIN $BIN/shadowprobe \
  --server <server-url> --user <account> --seconds 15 --dump /tmp/frame.png
# 密码来源：--password > $SHADOWDESK_PASSWORD > 钥匙串
```

> 注意：`dist/ShadowDesk.app` 是 ad-hoc 签名，仅适合本机使用；发布需替换为
> Developer ID 签名/公证。命令行运行 SPM 产物时需要
> `DYLD_FRAMEWORK_PATH=$(swift build --show-bin-path)`，App 包由脚本自动修好 rpath。

## 应用菜单（View）

| 菜单项 | 快捷键 | 作用 |
|---|---|---|
| 1:1 原生像素（禁用 HiDPI 放大） | ⌥⌘1 | 切换 1:1 模式（持久化到 UserDefaults） |
| 无损色彩（Y444） | — | 仅当服务端 encoder 支持时显示；切换会重置管线，黑屏数秒后恢复 |
| 请求关键帧 | ⌥⌘K | 发送 `recover` |
| 自动同步剪贴板 | — | 本地↔远端的自动同步开关（默认开，持久化） |
| 推送剪贴板到远端 | ⌥⌘V | 立即发送本地剪贴板 |
| 断开连接 | ⇧⌘D | 登出并释放远端 worker |
| 显示日志 / 显示帮助 | — | 切换叠加层 |

## 本地命令

`Ctrl+Opt+Shift+键` 直接触发：

| 键 | 作用 |
|---|---|
| `F` / `F11` | 全屏 |
| `1` / `F1` | 日志叠加层 |
| `2` / `F2` | 帮助 |
| `K` | 请求关键帧（`recover`） |
| `V` | 推送本地剪贴板 |
| `L` | 登出 |
| `Q` | 退出 |

本地命令按 keyCode 匹配，所以 `Shift+1` 这类被 Shift 改成 `!` 的字符也能命中。
指针接管/交还完全自动（移入画面接管、移出画面交还），不占用快捷键。

其余按键（含 `Esc`、`F1…F12`、`Ctrl+Alt+Del`）原样转发给远端。

## 键盘转发的三个 macOS 细节

`KeyboardMapping`（Kit，带单测）负责把原生事件映射成浏览器 `KeyboardEvent.key`：

- **Control 组合**：AppKit 把 `Ctrl+C` 报成控制字符 `0x03`，必须改用
  `charactersIgnoringModifiers` 取基础键（否则远端收不到任何 Ctrl 组合）；
- **Command 组合**：macOS 把 Cmd 组合走 key-equivalent 路径，`NSApplication.sendEvent:`
  **在事件到达响应链之前就吞掉 keyUp**（Mozilla bug 1299553、Chromium
  "Send Cmd+KeyUp events directly to application key window"）。用局部
  `NSEvent.addLocalMonitorForEvents(matching: .keyUp)` 在分发前截获并转发
  （Chromium / Ghostty / TigerVNC 同款做法），保证远端拿到真实的按下与抬起；
- **本地命令组合**：`Ctrl+Opt+Shift+键` 直接触发，按 keyCode 匹配（Shift 把 `1` 变成 `!`
  也能命中）；被本地命令消费的键其 key-up 同样不能再转给远端。

## 无损色彩模式（Y444）

服务端把 `video_format` 切成 `Y444` 后，管线以 4:4:4 全色度编码（彩色细字/细线不再有
色度渗色），视频流转为 H.264 High 4:4:4 Predictive。

客户端侧的完整链路：

- 菜单开关发送 `video_format,Y444` / `video_format,I420`；服务端换格式会**重建管线**，
  所有观看者黑屏 5–8 秒重连（服务端固有行为）；
- H.264 解码走 FFmpeg：libwebrtc 自带的 VideoToolbox 路径不支持 4:4:4，
  自定义 `RTCVideoDecoderFactory` 把 H264 分给 `FFmpegH264Decoder`，VP8/VP9 保持默认；
- 解码产出 `PlanarYUVBuffer`（I444 时色度与亮度同分辨率），`YUVMetalView` 三个平面
  直渲，不做 `toI420` 降采样——色彩精度一路保到屏幕。

代价：软件解码 CPU 占用高于 VideoToolbox；4:4:4 码率约为同画面 VP8 的 2–3 倍。
