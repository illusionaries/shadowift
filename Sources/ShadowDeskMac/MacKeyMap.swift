import AppKit
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
