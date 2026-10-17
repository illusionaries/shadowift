import AppKit
import ShadowDeskKit
import SwiftUI

@main
struct ShadowDeskApp: App {
    /// The session belonging to the focused window; menu commands act on it.
    @FocusedObject private var model: AppModel?

    var body: some Scene {
        // A WindowGroup with the default New Window (Cmd+N) command: every
        // window is an independent session, which is how parallel
        // connections are made.
        WindowGroup("ShadowDesk", id: "main") {
            SessionView()
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            // Session and display commands live in the standard View menu.
            CommandGroup(after: .toolbar) {
                if let model {
                    if model.phase == .connected {
                        Toggle("1:1 原生像素（禁用 HiDPI 放大）", isOn: Binding(
                            get: { model.nativePixelMode },
                            set: { model.nativePixelMode = $0 }
                        ))
                        .keyboardShortcut("1", modifiers: [.command, .option])
                        if model.losslessColorAvailable {
                            Toggle("无损色彩（Y444）", isOn: Binding(
                                get: { model.losslessColorActive },
                                set: { model.setLosslessColor($0) }
                            ))
                        }
                        if model.nativePixelCapped {
                            Text("远端显示上限约 1918×1078，已按比例缩小")
                        }
                        Divider()
                        Button("请求关键帧") { model.perform(.requestKeyFrame) }
                            .keyboardShortcut("k", modifiers: [.command, .option])
                        Toggle("自动同步剪贴板", isOn: Binding(
                            get: { model.clipboardSyncEnabled },
                            set: { model.clipboardSyncEnabled = $0 }
                        ))
                        Button("推送剪贴板到远端") { model.perform(.pushClipboard) }
                            .keyboardShortcut("v", modifiers: [.command, .option])
                        Divider()
                        Button("断开连接") { model.signOut() }
                            .keyboardShortcut("d", modifiers: [.command, .shift])
                    } else {
                        Button("重新连接") { model.retry() }
                            .disabled(model.user.isEmpty)
                        Divider()
                    }
                    Button(model.showLog ? "隐藏日志" : "显示日志") { model.perform(.toggleLog) }
                    Button(model.showHelp ? "隐藏帮助" : "显示帮助") { model.perform(.toggleHelp) }
                }
            }
        }
    }
}

/// One window = one independent session: each window owns its AppModel and
/// publishes it so the menu commands can reach the focused session.
struct SessionView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        RootView(model: model)
            .focusedSceneObject(model)
            .navigationTitle(model.windowTitle)
            .background(WindowReader { window in
                model.window = window
                WindowGeometry.apply(for: model.phase, window: window)
            })
            // Closing the window tears down its connection.
            .onDisappear { model.signOut() }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .login, .failed:
                LoginView(model: model)
            case .connecting:
                ConnectingView(model: model)
            case .connected:
                DesktopView(model: model)
            }
        }
        .frame(
            minWidth: model.phase == .connected ? 640 : 380,
            minHeight: model.phase == .connected ? 420 : 480
        )
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            model.handleLaunchArguments()
        }
        .onChange(of: model.phase) { _, phase in
            WindowGeometry.apply(for: phase, window: model.window)
        }
    }
}
