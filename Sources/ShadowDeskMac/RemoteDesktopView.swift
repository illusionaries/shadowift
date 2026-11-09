import AppKit
import ShadowDeskKit
import SwiftUI
@preconcurrency import WebRTC

/// Hosts the libwebrtc Metal view and translates AppKit events into control
/// commands. Pointer capture follows the "absolute coordinates, never move the
/// local cursor" model: the local cursor is merely hidden while the remote
/// owns the pointer.
struct RemoteDesktopView: NSViewRepresentable {
    var track: ShadowDeskKit.VideoTrack?
    var videoSize: CGSize?
    var cursor: CursorUpdate?
    var cursorImage: CGImage?
    var isConnected: Bool

    /// Height of the status bar drawn over the bottom edge, in points. The
    /// video view owns every pointer event, so the bar's hover state has to be
    /// derived here (a SwiftUI `onHover` on the bar would never fire: it is
    /// click-through so the pointer can reach the remote desktop).
    var statusBarZoneHeight: CGFloat = 0

    var onCommand: (ControlCommand) -> Void
    var onLocalCommand: (LocalCommand) -> Void
    var onCaptureChanged: (Bool) -> Void
    /// Whether the pointer currently sits in the status bar's strip.
    var onStatusBarHoverChanged: (Bool) -> Void = { _ in }
    /// Viewport in points plus the window's backing scale factor, so the model
    /// can request either CSS pixels (1×) or native device pixels.
    var onViewportChanged: (CGSize, CGFloat) -> Void

    func makeNSView(context: Context) -> RemoteDesktopNSView {
        let view = RemoteDesktopNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: RemoteDesktopNSView, context: Context) {
        configure(view)
        view.setTrack(track)
        view.videoSize = videoSize
        view.setCursor(update: cursor, image: cursorImage)
        view.isConnected = isConnected
    }

    private func configure(_ view: RemoteDesktopNSView) {
        view.onCommand = onCommand
        view.onLocalCommand = onLocalCommand
        view.onCaptureChanged = onCaptureChanged
        view.onStatusBarHoverChanged = onStatusBarHoverChanged
        view.onViewportChanged = onViewportChanged
        // Setting the height may finish the pointer's hover state asynchronously,
        // never inside SwiftUI's update pass.
        view.statusBarZoneHeight = statusBarZoneHeight
    }
}

final class RemoteDesktopNSView: NSView {
    private let videoView = YUVMetalView(frame: .zero)
    private let cursorView = NSImageView()
    private var trackingArea: NSTrackingArea?

    private var track: ShadowDeskKit.VideoTrack?
    private var cursorImage: CGImage?
    private var cursorUpdate: CursorUpdate?
    private var pointer = CGPoint.zero
    private var pointerInside = false
    private var windowIsKey = false
    private var captured = false
    private var cursorHidden = false
    private var statusBarHovered = false
    /// Key consumed as a local command; its matching key-up must not leak to
    /// the remote either.
    private var swallowedKeyCode: UInt16?
    private var pressedModifiers: Set<UInt16> = []
    private let keyUpMonitor = EventMonitorToken()

    var videoSize: CGSize?
    var isConnected = false { didSet { updateCapture() } }

    /// Height of the status bar overlay on the bottom edge; the bar fades away
    /// while the pointer is inside this strip so it never covers the picture
    /// (it has no controls, so it does not need to stay interactive).
    var statusBarZoneHeight: CGFloat = 0 {
        didSet {
            guard statusBarZoneHeight != oldValue else { return }
            scheduleStatusBarHoverUpdate()
        }
    }

    var onCommand: ((ControlCommand) -> Void)?
    var onLocalCommand: ((LocalCommand) -> Void)?
    var onCaptureChanged: ((Bool) -> Void)?
    var onStatusBarHoverChanged: ((Bool) -> Void)?
    var onViewportChanged: ((CGSize, CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        cursorView.imageScaling = .scaleNone
        cursorView.isHidden = true
        addSubview(cursorView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Track and cursor

    func setTrack(_ track: ShadowDeskKit.VideoTrack?) {
        guard let track else {
            self.track = nil
            updateCapture()
            return
        }
        if let current = self.track, current.raw === track.raw { return }
        self.track = track
        track.attach(videoView)
        updateCapture()
    }

    func setCursor(update: CursorUpdate?, image: CGImage?) {
        cursorUpdate = update
        cursorImage = image
        updateCursorView()
    }

    /// Draws the remote pointer so that its hotspot sits exactly on the view
    /// point that maps to the pixel coordinate we forwarded. The manager does
    /// not paint the cursor into the video, so this is the only visible pointer
    /// while the remote owns it.
    private func updateCursorView() {
        guard captured, cursorUpdate?.visible ?? true else {
            cursorView.isHidden = true
            return
        }
        guard let rect = videoRect(), let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            cursorView.isHidden = true
            return
        }
        let scaleX = rect.width / videoSize.width
        let scaleY = rect.height / videoSize.height

        let image: NSImage
        let sourceSize: CGSize
        let hotSpot: CGPoint // in image pixels

        if let cursorImage, cursorUpdate?.usesDefaultPointer != true {
            sourceSize = CGSize(width: cursorImage.width, height: cursorImage.height)
            hotSpot = CGPoint(x: cursorUpdate?.hotSpotX ?? 0, y: cursorUpdate?.hotSpotY ?? 0)
            image = NSImage(cgImage: cursorImage, size: sourceSize)
        } else {
            // serial == 0: the remote uses its default pointer, so borrow the
            // local system arrow and its real hotspot.
            let arrow = NSCursor.arrow.image
            image = arrow
            sourceSize = arrow.size
            hotSpot = NSCursor.arrow.hotSpot
        }

        // Draw at the video's display scale so the pointer keeps the remote's
        // apparent size, and anchor it so the hotspot lands exactly on the
        // pixel coordinate we forwarded.
        let drawnSize = CGSize(width: sourceSize.width * scaleX, height: sourceSize.height * scaleY)
        let hotSpotPoints = CGPoint(x: hotSpot.x * scaleX, y: hotSpot.y * scaleY)

        let anchor = cursorAnchor()
        let anchorX = anchor.x
        let anchorY = anchor.y

        cursorView.image = image
        cursorView.imageScaling = .scaleProportionallyUpOrDown
        cursorView.frame = NSRect(
            x: anchorX - hotSpotPoints.x,
            y: anchorY - hotSpotPoints.y,
            width: drawnSize.width,
            height: drawnSize.height
        )
        cursorView.isHidden = false
    }

    /// The view point that the forwarded pixel coordinate maps to; this is
    /// where the cursor's hotspot must land.
    private func cursorAnchor() -> CGPoint {
        guard let rect = videoRect(), let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            return pointer
        }
        let scaleX = rect.width / videoSize.width
        let scaleY = rect.height / videoSize.height
        guard let pixel = videoPixel(from: pointer) else { return pointer }
        return CGPoint(x: rect.minX + CGFloat(pixel.x) * scaleX,
                       y: rect.minY + CGFloat(pixel.y) * scaleY)
    }

    // MARK: - View lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)

        guard let window else { return }
        window.makeFirstResponder(self)
        windowIsKey = window.isKeyWindow
        reportViewport()

        installKeyUpMonitorIfNeeded()
        scheduleStatusBarHoverUpdate()
        // Selector based observers are removed automatically on dealloc.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowDidBecomeKey() {
        windowIsKey = true
        window?.makeFirstResponder(self)
        reportViewport()
        updateCapture()
        scheduleStatusBarHoverUpdate()
    }

    @objc private func windowDidResignKey() {
        windowIsKey = false
        updateCapture()
        // Losing key means no key events reach us any more — including the
        // release of a modifier that is still held. Release ours now, or the
        // remote keeps acting as if Command were down (every drag becomes a
        // window move) once focus comes back.
        releasePressedModifiers()
        setStatusBarHovered(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportViewport()
        // The strip is anchored to the bottom edge, so a resize can move it
        // under a stationary pointer.
        scheduleStatusBarHoverUpdate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportViewport()
    }

    private func reportViewport() {
        onViewportChanged?(bounds.size, window?.backingScaleFactor ?? 1)
    }

    // MARK: - Status bar hover

    /// The status bar is click-through, so it never receives its own hover
    /// events; the pointer is tracked here instead and the strip above it is
    /// reported as "hovered" whenever the local or forwarded pointer is inside.
    private func updateStatusBarHover() {
        let point: CGPoint
        let inside: Bool
        if pointerInside {
            point = pointer
            inside = true
        } else if let window, window.isKeyWindow {
            // Covers the case where the view appears with the pointer already
            // parked over the bar: no mouseMoved has been delivered yet.
            point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            inside = bounds.contains(point)
        } else {
            point = .zero
            inside = false
        }
        setStatusBarHovered(inside && statusBarZoneContains(point))
    }

    private func statusBarZoneContains(_ point: CGPoint) -> Bool {
        guard statusBarZoneHeight > 0 else { return false }
        return point.y >= bounds.height - statusBarZoneHeight
    }

    private func setStatusBarHovered(_ hovered: Bool) {
        guard hovered != statusBarHovered else { return }
        statusBarHovered = hovered
        onStatusBarHoverChanged?(hovered)
    }

    /// Runs outside SwiftUI's update/layout pass, so reporting the state back
    /// (it drives a `@State` there) is safe.
    private func scheduleStatusBarHoverUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusBarHover()
        }
    }

    // MARK: - Pointer capture

    private func updateCapture() {
        let shouldCapture = track != nil
            && isConnected
            && pointerInside
            && windowIsKey
            && videoRect() != nil
        guard shouldCapture != captured else { return }
        if shouldCapture {
            // Focus may have been elsewhere while a modifier was released; let
            // the remote catch up before it sees the first forwarded event.
            releaseStaleModifiers()
        }
        captured = shouldCapture
        if captured {
            NSCursor.hide()
            cursorHidden = true
            sendAbsolutePointer()
        } else if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        updateCursorView()
        onCaptureChanged?(captured)
    }

    /// The letterboxed video rectangle inside the view (aspect fit).
    private func videoRect() -> CGRect? {
        guard let size = videoSize, size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1
        else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let displayed = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (bounds.width - displayed.width) / 2,
            y: (bounds.height - displayed.height) / 2,
            width: displayed.width,
            height: displayed.height
        )
    }

    /// View point → remote video pixel, or nil when outside the picture.
    private func videoPixel(from point: CGPoint) -> (x: Int, y: Int)? {
        guard let rect = videoRect(), rect.contains(point), let size = videoSize else { return nil }
        let x = ((point.x - rect.minX) / rect.width * size.width).rounded()
        let y = ((point.y - rect.minY) / rect.height * size.height).rounded()
        return (
            x: min(max(Int(x), 0), Int(size.width) - 1),
            y: min(max(Int(y), 0), Int(size.height) - 1)
        )
    }

    private func sendAbsolutePointer() {
        guard captured, let pixel = videoPixel(from: pointer) else { return }
        onCommand?(.mouseMove(x: pixel.x, y: pixel.y))
    }

    // MARK: - Modifier reconciliation

    /// A modifier key-up can be lost without our window ever resigning key: a
    /// system shortcut such as Cmd+Space or Cmd+Shift+4 hands the keyboard to
    /// another app or to a system panel, which swallows the release. The
    /// remote then keeps acting as if Command were held — on macOS every drag
    /// becomes a window move. Releasing the modifiers we forwarded re-aligns
    /// the two sides. Only releases are injected: the physical state is never
    /// pressed onto the remote behind the user's back.
    private func releaseStaleModifiers() {
        guard !pressedModifiers.isEmpty else { return }
        let physical = MacKeyMap.currentModifiers()
        let stale = pressedModifiers.filter {
            !KeyboardMapping.isModifierDown(keyCode: $0, modifiers: physical)
        }
        guard !stale.isEmpty else { return }
        pressedModifiers.subtract(stale)
        sendModifierKeyUps(for: stale)
    }

    /// Releases every forwarded modifier. Used when the window loses key: from
    /// then on no key event reaches us, so the remote must not be left with any
    /// of them held.
    private func releasePressedModifiers() {
        guard !pressedModifiers.isEmpty else { return }
        let released = pressedModifiers
        pressedModifiers.removeAll()
        sendModifierKeyUps(for: released)
    }

    private func sendModifierKeyUps(for keyCodes: Set<UInt16>) {
        for keyCode in keyCodes {
            if let name = KeyboardMapping.modifierName(keyCode: keyCode) {
                onCommand?(.keyUp(name))
            }
        }
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        pointerInside = true
        updateCapture()
        updateCursorView()
        updateStatusBarHover()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateCapture()
        // Leaving the picture always brings the readout back, even if the exit
        // happened through the bottom edge where the strip lives.
        setStatusBarHovered(false)
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        // Movement is the first event after coming back from a system shortcut,
        // so this settles a swallowed modifier release before any drag starts.
        releaseStaleModifiers()
        updateCursorView()
        sendAbsolutePointer()
        updateStatusBarHover()
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard captured else { updateCapture(); return }
        releaseStaleModifiers()
        onCommand?(.mouseDown(.left))
    }

    override func mouseUp(with event: NSEvent) {
        guard captured else { return }
        onCommand?(.mouseUp(.left))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard captured else { return }
        releaseStaleModifiers()
        onCommand?(.mouseDown(.right))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard captured else { return }
        onCommand?(.mouseUp(.right))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard captured else { return }
        releaseStaleModifiers()
        onCommand?(.mouseDown(.middle))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard captured else { return }
        onCommand?(.mouseUp(.middle))
    }

    override func scrollWheel(with event: NSEvent) {
        guard captured else { return }
        releaseStaleModifiers()
        if event.hasPreciseScrollingDeltas {
            onCommand?(.trackpadScroll(delta: Int(event.scrollingDeltaY)))
        } else {
            onCommand?(.wheel(up: event.scrollingDeltaY > 0))
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if handleLocalKey(event) { return }
        guard captured, let key = MacKeyMap.browserKey(for: event) else { return }
        releaseStaleModifiers()
        onCommand?(.keyDown(key))
    }

    override func keyUp(with event: NSEvent) {
        // Command releases arrive through the local monitor instead.
        if event.modifierFlags.contains(.command) { return }
        if event.keyCode == swallowedKeyCode {
            swallowedKeyCode = nil
            return
        }
        guard captured, let key = MacKeyMap.browserKey(for: event) else { return }
        onCommand?(.keyUp(key))
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard let name = MacKeyMap.modifierKey(for: event) else { return }
        let isDown = MacKeyMap.isModifierDown(keyCode: event.keyCode, flags: flags)
        if isDown {
            // Presses stop being forwarded as soon as the pointer hands the
            // remote back; the menu bar keeps working locally.
            guard captured, !pressedModifiers.contains(event.keyCode) else { return }
            pressedModifiers.insert(event.keyCode)
            onCommand?(.keyDown(name))
        } else if pressedModifiers.contains(event.keyCode) {
            // Releases are always forwarded, even when the remote has already
            // been handed back: we pressed this key on the remote, so it must
            // hear the key-up. Key events keep coming to this view while the
            // window stays key, regardless of where the pointer is.
            pressedModifiers.remove(event.keyCode)
            onCommand?(.keyUp(name))
        }
    }

    /// AppKit routes Command combinations through the key-equivalent path and
    /// drops the matching key-up before it reaches the responder chain (see
    /// Chromium's "Send Cmd+KeyUp events directly to application key window"
    /// and Mozilla bug 1299553). A local event monitor runs before that
    /// dispatch, so it is the only place the release can be observed.
    private func installKeyUpMonitorIfNeeded() {
        guard keyUpMonitor.token == nil else { return }
        keyUpMonitor.token = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard let self, self.captured, event.window === self.window else { return event }
            guard event.modifierFlags.contains(.command),
                  let key = MacKeyMap.browserKey(for: event)
            else { return event }
            self.onCommand?(.keyUp(key))
            return nil
        }
    }

    /// `Ctrl+Opt+Shift+<key>` fires a local command instead of being sent to
    /// the remote. Matching is by key code, so Shift-altered characters
    /// (`Shift+1` arrives as `!`) still resolve.
    private func handleLocalKey(_ event: NSEvent) -> Bool {
        let chord: NSEvent.ModifierFlags = [.control, .option, .shift]
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isSuperset(of: chord),
              let command = Self.localCommand(forKeyCode: event.keyCode)
        else { return false }
        swallowedKeyCode = event.keyCode
        onLocalCommand?(command)
        return true
    }

    private static func localCommand(forKeyCode keyCode: UInt16) -> LocalCommand? {
        switch keyCode {
        case 18, 122: return .toggleLog // 1, F1
        case 19, 120: return .toggleHelp // 2, F2
        case 3, 103: return .toggleFullScreen // F, F11
        case 40: return .requestKeyFrame // K
        case 9: return .pushClipboard // V
        case 37: return .logout // L
        case 12: return .quit // Q
        default: return nil
        }
    }

    deinit {
        if cursorHidden {
            NSCursor.unhide()
        }
    }
}




/// Keeps the local event monitor token alive and removes it on dealloc.
private final class EventMonitorToken: @unchecked Sendable {
    var token: Any?
    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}
