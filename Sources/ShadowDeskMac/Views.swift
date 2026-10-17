import AppKit
import ShadowDeskKit
import SwiftUI

// MARK: - Login

struct LoginView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focus: Field?

    private enum Field { case server, user, password }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 20)
            panel
            if case let .failed(message) = model.phase {
                error(message)
                    .padding(.top, 12)
            }
            options
                .padding(.top, 14)
            actions
                .padding(.top, 14)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear {
            focus = model.user.isEmpty ? .user : .password
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text("ShadowDesk")
                .font(.title2.weight(.semibold))
            if let version {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: Form

    private var panel: some View {
        VStack(spacing: 0) {
            row(icon: "server.rack") {
                TextField("", text: $model.server, prompt: Text("服务器地址（https://…）"))
                    .focused($focus, equals: .server)
                    .onSubmit { model.signIn() }
            }
            rowDivider
            row(icon: "person") {
                TextField("", text: $model.user, prompt: Text("账号"))
                    .focused($focus, equals: .user)
                    .onSubmit { model.signIn() }
            }
            rowDivider
            row(icon: "lock") {
                SecureField("", text: $model.password, prompt: Text(
                    model.savedPasswordLikelyAvailable ? "已存钥匙链，可留空" : "密码"
                ))
                    .focused($focus, equals: .password)
                    .onSubmit { model.signIn() }
            }
        }
        .background(panelBackground)
    }

    private func row<Content: View>(
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            content()
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 43)
    }

    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
        }
    }

    private func error(_ message: String) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .textSelection(.enabled)
    }

    private var options: some View {
        HStack {
            Toggle("记住密码", isOn: $model.rememberPassword)
                .toggleStyle(.checkbox)
                .font(.callout)
            Spacer()
            if !model.history.entries.isEmpty {
                Menu {
                    ForEach(model.history.entries) { entry in
                        Button("\(entry.username) · \(entry.server)") {
                            model.server = entry.server
                            model.user = entry.username
                            model.password = ""
                            focus = .password
                        }
                    }
                } label: {
                    Label("最近使用", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .font(.callout)
                .fixedSize()
            }
        }
    }

    private var actions: some View {
        Button {
            model.signIn()
        } label: {
            Text("登录")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
        .disabled(model.user.isEmpty)
    }
}

// MARK: - Connecting

struct ConnectingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text(model.status.isEmpty ? "正在连接…" : model.status)
                    .font(.headline)
                Text("\(model.user) · \(model.server)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("取消") { model.signOut() }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}

// MARK: - Desktop

struct DesktopView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteDesktopView(
                track: model.videoTrack,
                videoSize: model.remoteSize.map { CGSize(width: $0.width, height: $0.height) },
                cursor: model.cursor,
                cursorImage: model.cursorImage,
                isConnected: model.phase == .connected,
                onCommand: { model.send($0) },
                onLocalCommand: { model.perform($0) },
                onCaptureChanged: { model.setCaptured($0) },
                onViewportChanged: { size, scale in
                    model.requestResolution(for: size, backingScale: scale)
                }
            )
            .background(Color.black)

            StatusBar(model: model)
        }
        .overlay(alignment: .topTrailing) {
            if model.showLog {
                LogOverlay(logs: model.logs)
            }
        }
        .overlay {
            if model.showHelp {
                HelpOverlay()
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(model.captured ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.captured ? "指针已接管" : "本地指针")
            Text(hint)
                .foregroundStyle(.secondary)
            Spacer()
            if let size = model.remoteSize {
                Text("\(size.width)×\(size.height)")
            }
            if model.nativePixelMode {
                Text(model.nativePixelAchieved ? "1:1" : "1:1 已裁剪")
                    .foregroundStyle(model.nativePixelAchieved ? Color.green : Color.orange)
            }
            if model.losslessColorActive {
                Text("Y444")
                    .foregroundStyle(.purple)
            }
            Text(String(format: "%.0f fps", model.fps))
            Text(String(format: "%.0f kbps", model.bitrate))
            if let latency = model.latency {
                Text("RTT \(latency) ms")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var hint: String {
        model.captured
            ? "移出画面即交还指针"
            : "把指针移入画面即可接管"
    }
}

// MARK: - Overlays

struct LogOverlay: View {
    var logs: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(width: 520, height: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct HelpOverlay: View {
    private let commands: [(String, String)] = [
        ("Ctrl+Opt+Shift+F / F11", "全屏"),
        ("Ctrl+Opt+Shift+1 / F1", "日志"),
        ("Ctrl+Opt+Shift+2 / F2", "本帮助"),
        ("Ctrl+Opt+Shift+K", "请求关键帧"),
        ("Ctrl+Opt+Shift+V", "把本机剪贴板发送到远端"),
        ("Ctrl+Opt+Shift+L", "退出登录"),
        ("Ctrl+Opt+Shift+Q", "退出"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本地快捷键")
                .font(.headline)
            ForEach(commands, id: \.0) { key, description in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(key)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Text(description)
                }
            }
            Text("其余按键（包括 Esc、F1…F12、Ctrl+Alt+Del）都会原样发送到远端；把指针移出画面即交还给本机。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Window geometry

/// Login is a compact window; the desktop needs room. Sizes are swapped when
/// the session starts or ends, keeping the window on screen.
@MainActor
enum WindowGeometry {
    static let compact = CGSize(width: 420, height: 500)
    private static let defaultDesktop = CGSize(width: 1280, height: 820)
    private static let desktopSizeKey = "desktopWindowSize"

    static func apply(for phase: AppModel.Phase) {
        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.canBecomeMain })
        else { return }

        if phase == .connected {
            set(window: window, contentSize: storedDesktopSize())
        } else {
            rememberDesktopSize(window)
            set(window: window, contentSize: compact)
        }
    }

    private static func rememberDesktopSize(_ window: NSWindow) {
        let content = window.contentRect(forFrameRect: window.frame).size
        guard content.width > 700, content.height > 400 else { return }
        UserDefaults.standard.set([content.width, content.height], forKey: desktopSizeKey)
    }

    private static func storedDesktopSize() -> CGSize {
        guard let values = UserDefaults.standard.array(forKey: desktopSizeKey) as? [Double],
              values.count == 2
        else { return defaultDesktop }
        return CGSize(width: values[0], height: values[1])
    }

    private static func set(window: NSWindow, contentSize: CGSize) {
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - contentSize.width) > 1 || abs(current.height - contentSize.height) > 1 else {
            return
        }
        var frame = window.frame
        frame.size = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        ).size
        frame.origin.y = window.frame.maxY - frame.height
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 16), visible.maxX - frame.width - 16)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 16), visible.maxY - frame.height - 16)
        }
        window.setFrame(frame, display: true, animate: true)
    }
}
