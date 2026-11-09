import AppKit
import CoreGraphics
import ShadowDeskKit

/// Thin AppKit adapter over ``KeyboardMapping``.
enum MacKeyMap {
    static func browserKey(for event: NSEvent) -> String? {
        KeyboardMapping.keyName(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers(from: event.modifierFlags)
        )
    }

    static func modifierKey(for event: NSEvent) -> String? {
        KeyboardMapping.modifierName(keyCode: event.keyCode)
    }

    static func isModifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        KeyboardMapping.isModifierDown(keyCode: keyCode, modifiers: modifiers(from: flags))
    }

    /// The modifier state from the combined session event source. Unlike an
    /// event's own flags these keep reflecting the keyboard while another app
    /// or a system panel (Spotlight, screenshot crosshair) owns input, which is
    /// exactly when a key-up can be lost on the way to us.
    ///
    /// `NSEvent.ModifierFlags` and `CGEventFlags` share their bit layout, so
    /// the converted value is meaningful for `modifiers(from:)`.
    static func currentModifiers() -> KeyboardMapping.Modifiers {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return modifiers(from: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyboardMapping.Modifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: KeyboardMapping.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}
