import AppKit
import ShadowDeskKit

/// Actions a user can trigger locally without them reaching the remote host.
enum LocalCommand {
    case toggleLog
    case toggleHelp
    case toggleFullScreen
    case requestKeyFrame
    case pushClipboard
    case logout
    case quit
}

private let nativePixelKey = "nativePixelMode"
private let clipboardSyncKey = "clipboardSyncEnabled"

/// UI facing state for one ShadowDesk connection.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case login
        case connecting
        case connected
        case failed(String)
    }

    @Published var server = ""
    @Published var user = ""
    @Published var password = ""
    @Published var rememberPassword = true

    @Published private(set) var phase: Phase = .login
    @Published private(set) var status = ""
    @Published private(set) var logs: [String] = []
    @Published private(set) var latency: Int?
    @Published private(set) var remoteSize: ServerConfig.VideoSize?
    @Published private(set) var serverConfig: ServerConfig?
    @Published private(set) var fps: Double = 0
    @Published private(set) var bitrate: Double = 0
    /// The last resolution we asked for (in video pixels).
    @Published private(set) var requestedPixelSize: ServerConfig.VideoSize?
    @Published private(set) var videoTrack: VideoTrack?
    @Published private(set) var cursor: CursorUpdate?
    @Published private(set) var cursorImage: CGImage?
    @Published private(set) var captured = false
    @Published var showLog = false
    @Published var showHelp = false

    /// Automatically forwards local clipboard changes to the remote (and keeps
    /// the two pasteboards apart when the remote echoes a change we made).
    @Published var clipboardSyncEnabled: Bool = UserDefaults.standard.object(forKey: clipboardSyncKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(clipboardSyncEnabled, forKey: clipboardSyncKey)
            if clipboardSyncEnabled {
                startClipboardSync()
            } else {
                clipboardTask?.cancel()
                clipboardTask = nil
            }
        }
    }

    /// When enabled the client asks the agent for one video pixel per physical
    /// display pixel (window points × backing scale) instead of the default
    /// CSS-pixel sizing, so nothing is upscaled by the GPU on Retina screens.
    @Published var nativePixelMode: Bool = UserDefaults.standard.bool(forKey: nativePixelKey) {
        didSet {
            UserDefaults.standard.set(nativePixelMode, forKey: nativePixelKey)
            lastRequestedSize = nil
            requestResolution(for: lastViewportPoints, backingScale: lastBackingScale)
        }
    }

    private let maxVideoWidth = 4096
    private let maxVideoHeight = 2304
    private var lastViewportPoints: CGSize = .zero
    private var lastBackingScale: CGFloat = 1

    let history = HistoryStore()

    /// `--verbose` mirrors the in-app log to stderr (handy when launched from
    /// a terminal or a script).
    private let verbose = CommandLine.arguments.contains("--verbose")

    private var client: ShadowDeskClient?
    private var pump: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var previousStats: PeerSession.MediaStats?
    private var previousStatsAt = Date()
    private var lastRequestedSize: ServerConfig.VideoSize?
    private var resolutionTask: Task<Void, Never>?
    private let pasteboard = PasteboardBridge()
    private var clipboardTask: Task<Void, Never>?
    private var lastClipboardText: String?
    private var lastPasteboardChangeCount = -1

    /// True when the agent is actually producing one pixel per display pixel.
    var nativePixelAchieved: Bool {
        guard nativePixelMode, let requested = requestedPixelSize, let actual = remoteSize else {
            return false
        }
        return actual.width >= requested.width - 2 && actual.height >= requested.height - 2
    }

    /// True when 1:1 was requested but the agent's display is too small.
    var nativePixelCapped: Bool {
        nativePixelMode && requestedPixelSize != nil && !nativePixelAchieved
    }

    /// The agent offers Y444 (it runs an encoder that supports 4:4:4).
    var losslessColorAvailable: Bool {
        serverConfig?.videoFormats?.contains { $0.uppercased() == "Y444" } ?? false
    }

    var losslessColorActive: Bool {
        serverConfig?.videoFormat?.uppercased() == "Y444"
    }

    /// Switches the pipeline between Y444 and I420. The agent rebuilds the
    /// pipeline for a format change, so the video freezes for a few seconds.
    func setLosslessColor(_ enabled: Bool) {
        guard phase == .connected else { return }
        send(.videoFormat(enabled ? "Y444" : "I420"))
        status = enabled ? "正在切换到无损色彩…" : "正在切换到兼容色彩…"
    }
    private var retries = 0

    init() {
        if let entry = history.lastEntry {
            server = entry.server
            user = entry.username
        }
        rememberPassword = history.savePasswords
    }

    // MARK: - Sign in / out

    func signIn() {
        switch phase {
        case .login, .failed:
            break
        case .connecting, .connected:
            return
        }
        guard let url = ServerAddress.normalize(server) else {
            phase = .failed("Enter a server address")
            return
        }
        guard !user.isEmpty else {
            phase = .failed("Enter an account")
            return
        }
        // Only touch the keychain once the user actually asks to sign in:
        // reading at launch pops a permission dialog with no visible cause.
        if password.isEmpty {
            loadRememberedPassword()
        }
        guard !password.isEmpty else {
            phase = .failed("Enter a password")
            return
        }

        let server = url
        let username = user
        phase = .connecting
        status = "Signing in…"
        logs.removeAll()
        retries = 0

        rememberCredentials(server: server)
        history.touch(server: server, username: username)

        let client = ShadowDeskClient(configuration: .init(
            server: server,
            user: username,
            password: password
        ))
        self.client = client
        pump = Task { [weak self] in
            for await event in await client.events() {
                self?.handle(event)
            }
        }
        Task { [weak self] in
            do {
                try await client.start()
                self?.startStats()
            } catch {
                self?.phase = .failed(error.localizedDescription)
                self?.status = error.localizedDescription
            }
        }
    }

    func signOut() {
        pump?.cancel()
        pump = nil
        statsTask?.cancel()
        statsTask = nil
        clipboardTask?.cancel()
        clipboardTask = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        let client = client
        self.client = nil
        Task { await client?.stop() }
        videoTrack = nil
        cursor = nil
        cursorImage = nil
        latency = nil
        fps = 0
        bitrate = 0
        status = ""
        phase = .login
    }

    func retry() {
        signIn()
    }

    // MARK: - Commands

    func send(_ command: ControlCommand) {
        guard let client else { return }
        if verbose, command.isInterestingForLogging {
            FileHandle.standardError.write(Data("[send] \(command.encoded)\n".utf8))
        }
        Task { await client.send(command) }
    }

    func perform(_ command: LocalCommand) {
        switch command {
        case .toggleLog:
            showLog.toggle()
        case .toggleHelp:
            showHelp.toggle()
        case .toggleFullScreen:
            NSApp.keyWindow?.toggleFullScreen(nil)
        case .requestKeyFrame:
            send(.recover)
        case .pushClipboard:
            Task { [weak self] in
                guard let self else { return }
                let snapshot = await self.pasteboard.snapshot()
                guard !snapshot.isPrivate, let text = snapshot.text, !text.isEmpty else { return }
                self.lastClipboardText = text
                self.lastPasteboardChangeCount = snapshot.changeCount
                self.send(.clipboard(text))
            }
        case .logout:
            signOut()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// Called by the desktop view when the user takes/releases the pointer.
    func setCaptured(_ captured: Bool) {
        self.captured = captured
    }

    /// Sends a resolution request when the viewport changes substantially.
    ///
    /// `size` is in points (CSS pixels, like the web client). With
    /// ``nativePixelMode`` the request is scaled by the display's backing
    /// factor so one video pixel covers one physical pixel.
    ///
    /// Requests are debounced: while the window is resizing (a drag, or the
    /// animated layout change when signing in/out) every intermediate size is
    /// discarded, and only the size that stays put for a moment is sent. That
    /// keeps the remote from churning through resolutions it never displays.
    func requestResolution(for size: CGSize, backingScale: CGFloat = 1) {
        lastViewportPoints = size
        lastBackingScale = max(1, backingScale)
        guard phase == .connected, size.width > 100, size.height > 100 else { return }

        let scale = nativePixelMode ? lastBackingScale : 1
        var width = Int((size.width * scale).rounded())
        var height = Int((size.height * scale).rounded())

        // Keep the aspect ratio while staying inside the agent's comfort zone.
        let shrink = min(1, min(Double(maxVideoWidth) / Double(width), Double(maxVideoHeight) / Double(height)))
        if shrink < 1 {
            width = Int((Double(width) * shrink).rounded())
            height = Int((Double(height) * shrink).rounded())
        }

        let requested = ServerConfig.VideoSize(width: width, height: height)
        resolutionTask?.cancel()
        resolutionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.dispatchResolutionRequest(requested)
        }
    }

    private func dispatchResolutionRequest(_ requested: ServerConfig.VideoSize) {
        guard phase == .connected else { return }
        if let last = lastRequestedSize,
           abs(last.width - requested.width) <= 2,
           abs(last.height - requested.height) <= 2 {
            return
        }
        lastRequestedSize = requested
        requestedPixelSize = requested
        send(.resolution(width: requested.width, height: requested.height, adaptive: true))
        status = "Asking for \(requested.width)x\(requested.height)"
        if verbose {
            FileHandle.standardError.write(Data(
                "[resolution] viewport \(Int(lastViewportPoints.width))x\(Int(lastViewportPoints.height))pt ×\(lastBackingScale) -> \(requested.width)x\(requested.height)\n".utf8
            ))
        }
    }

    // MARK: - Event pump

    private func handle(_ event: ShadowDeskClient.Event) {
        switch event {
        case let .stateChanged(state):
            switch state {
            case .connected:
                phase = .connected
                status = "Connected"
                retries = 0
            case .connecting:
                status = "Negotiating…"
            case .closed where phase == .connected:
                signOut()
            default:
                break
            }

        case let .log(message):
            let stamp = Date().formatted(date: .omitted, time: .standard)
            logs.append("\(stamp)  \(message)")
            if logs.count > 400 { logs.removeFirst(logs.count - 400) }
            if verbose {
                FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
            }

        case let .serverConfig(config):
            serverConfig = config
            if let size = config.resolutionSize {
                remoteSize = size
            }

        case let .cursor(update):
            cursor = update
            cursorImage = update.usesDefaultPointer ? nil : CursorImageDecoder.image(from: update)

        case let .latency(milliseconds):
            latency = milliseconds

        case let .videoTrack(track):
            videoTrack = track

        case .controlChannelReady:
            status = "Interactive"
            startClipboardSync()
            lastRequestedSize = nil
            requestResolution(for: lastViewportPoints, backingScale: lastBackingScale)

        case let .clipboard(content):
            lastClipboardText = content
            Task { [weak self] in
                guard let self else { return }
                self.lastPasteboardChangeCount = await self.pasteboard.write(content)
                if self.verbose {
                    FileHandle.standardError.write(Data(
                        "[clipboard] remote -> local (\(content.count) chars)\n".utf8
                    ))
                }
            }

        case let .ended(reason):
            let message = reason ?? "session ended"
            status = message
            logs.append("ended: \(message)")
            if verbose {
                FileHandle.standardError.write(Data("ended: \(message)\n".utf8))
            }
            // Drop the session but stay on the login screen for a retry.
            let client = client
            self.client = nil
            Task { await client?.stop() }
            pump?.cancel()
            pump = nil
            statsTask?.cancel()
            statsTask = nil
            videoTrack = nil
            phase = .failed(message)
        }
    }

    /// macOS has no pasteboard change notification: the documented way to
    /// notice a copy is to poll `NSPasteboard.changeCount`. Poll twice a
    /// second while the app is frontmost, every two seconds in the background,
    /// and only while connected.
    private func startClipboardSync() {
        clipboardTask?.cancel()
        guard clipboardSyncEnabled else { return }
        clipboardTask = Task { [weak self] in
            guard let self else { return }
            let initial = await self.pasteboard.snapshot()
            self.lastPasteboardChangeCount = initial.changeCount
            if self.lastClipboardText == nil {
                self.lastClipboardText = initial.isPrivate ? nil : initial.text
            }
            while !Task.isCancelled {
                await self.pollClipboard()
                try? await Task.sleep(for: self.appIsActive
                    ? .milliseconds(500)
                    : .milliseconds(2000))
            }
        }
    }

    private var appIsActive: Bool { NSApp?.isActive ?? true }

    private func pollClipboard() async {
        guard phase == .connected, clipboardSyncEnabled else { return }
        if serverConfig?.clipboardEnabled == false { return }

        let snapshot = await pasteboard.snapshot()
        guard snapshot.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = snapshot.changeCount
        guard !snapshot.isPrivate,
              let text = snapshot.text,
              !text.isEmpty,
              text != lastClipboardText
        else { return }

        lastClipboardText = text
        send(.clipboard(text))
        if verbose {
            FileHandle.standardError.write(Data("[clipboard] local -> remote (\(text.count) chars)\n".utf8))
        }
    }

    private func startStats() {
        statsTask?.cancel()
        previousStats = nil
        previousStatsAt = Date()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.sampleStats()
            }
        }
    }

    private func sampleStats() async {
        guard let client, let stats = await client.mediaStats() else { return }
        let now = Date()
        if let previous = previousStats {
            let seconds = now.timeIntervalSince(previousStatsAt)
            if seconds > 0 {
                fps = Double(stats.framesDecoded - previous.framesDecoded) / seconds
                let bytes = Double(stats.bytesReceived - previous.bytesReceived)
                bitrate = bytes * 8 / seconds / 1000
            }
        }
        previousStats = stats
        previousStatsAt = now
        if verbose {
            FileHandle.standardError.write(Data(
                "[stats] decoded=\(stats.framesDecoded)/\(stats.framesReceived) keyframes=\(stats.keyFramesDecoded) size=\(stats.frameWidth)x\(stats.frameHeight)\n".utf8
            ))
        }
        if stats.frameWidth > 0 {
            remoteSize = .init(width: stats.frameWidth, height: stats.frameHeight)
        }
    }

    // MARK: - Credentials

    private func rememberCredentials(server: URL) {
        history.savePasswords = rememberPassword
        let service = Keychain.service(for: server)
        if rememberPassword, !password.isEmpty {
            try? Keychain.setPassword(password, service: service, account: user)
        } else if !rememberPassword {
            Keychain.deletePassword(service: service, account: user)
        }
    }

    func loadRememberedPassword() {
        guard password.isEmpty else { return }
        if let fromEnvironment = ProcessInfo.processInfo.environment["SHADOWDESK_PASSWORD"],
           !fromEnvironment.isEmpty {
            password = fromEnvironment
            return
        }
        let normalized = ServerAddress.normalize(server) ?? URL(string: server)!
        if let stored = Keychain.password(service: Keychain.service(for: normalized), account: user) {
            password = stored
        }
    }

    /// `--auto` connects straight away using the last profile and the
    /// keychain, which is handy for smoke tests and scripted launches.
    func handleLaunchArguments() {
        guard CommandLine.arguments.contains("--auto") else { return }
        signIn()
    }

    /// True when the current server/account pair probably has a keychain
    /// entry. Only consults the history file, never the keychain itself, so
    /// the login form can offer "leave blank to reuse" without triggering a
    /// permission prompt at launch.
    var savedPasswordLikelyAvailable: Bool {
        history.savePasswords && history.entries.contains {
            $0.username == user && $0.server == server
        }
    }
}

private extension ControlCommand {
    /// High frequency traffic (pointer, wheel, heartbeat) is skipped in the
    /// `--verbose` log so the interesting commands stay readable.
    var isInterestingForLogging: Bool {
        switch self {
        case .mouseMove, .mouseRelative, .trackpadScroll, .rtt:
            return false
        default:
            return true
        }
    }
}
