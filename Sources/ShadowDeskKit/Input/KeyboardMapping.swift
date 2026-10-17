import Foundation

/// Translates native key events into the browser `KeyboardEvent.key` names the
/// agent expects on the control channel.
///
/// The tricky part is which string to use: macOS reports Control combinations
/// as control characters (`Ctrl+C` is `0x03`) and Option combinations as
/// composed characters. A remote desktop wants the *base* key plus the
/// modifier key events that are sent separately, so Command/Option/Control fall
/// back to `charactersIgnoringModifiers` (which still applies Shift).
public enum KeyboardMapping {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)
        public static let function = Modifiers(rawValue: 1 << 5)
    }

    /// Browser key name, or `nil` when the event has no representable key.
    public static func keyName(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: Modifiers
    ) -> String? {
        if let special = specialKeys[keyCode] {
            return special
        }
        if let numpad = numpadKey(keyCode) {
            return numpad
        }

        var candidate = characters
        let needsBaseKey = modifiers.contains(.command)
            || modifiers.contains(.option)
            || modifiers.contains(.control)
        if needsBaseKey {
            candidate = charactersIgnoringModifiers
        }
        // Belt and braces: some Control combinations still arrive as C0
        // control characters, which are never valid `KeyboardEvent.key` names.
        if let text = candidate, isControlCharacter(text) {
            candidate = charactersIgnoringModifiers
        }

        guard let text = candidate, text.count == 1,
              let scalar = text.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F
        else { return nil }
        return text
    }

    /// Name of the modifier key an event refers to, for `flagsChanged`.
    public static func modifierName(keyCode: UInt16) -> String? {
        modifierKeys[keyCode]
    }

    /// Whether a modifier key with this code is currently held down.
    public static func isModifierDown(keyCode: UInt16, modifiers: Modifiers) -> Bool {
        switch keyCode {
        case 56, 60: return modifiers.contains(.shift)
        case 59, 62: return modifiers.contains(.control)
        case 58, 61: return modifiers.contains(.option)
        case 55, 54: return modifiers.contains(.command)
        case 57: return modifiers.contains(.capsLock)
        default: return false
        }
    }

    private static func isControlCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static let specialKeys: [UInt16: String] = [
        36: "Enter", 76: "Enter", // return, keypad enter
        48: "Tab",
        51: "Backspace",
        53: "Escape",
        117: "Delete",
        114: "Insert",
        115: "Home", 119: "End",
        116: "PageUp", 121: "PageDown",
        123: "ArrowLeft", 124: "ArrowRight",
        125: "ArrowDown", 126: "ArrowUp",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
    ]

    private static let modifierKeys: [UInt16: String] = [
        56: "Shift", 60: "Shift",
        59: "Control", 62: "Control",
        58: "Alt", 61: "AltGraph",
        55: "Meta", 54: "Meta",
        57: "CapsLock",
        63: "Fn",
    ]

    private static func numpadKey(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 82: return "0"
        case 83: return "1"
        case 84: return "2"
        case 85: return "3"
        case 86: return "4"
        case 87: return "5"
        case 88: return "6"
        case 89: return "7"
        case 91: return "8"
        case 92: return "9"
        case 65: return "Decimal"
        case 67: return "Multiply"
        case 69: return "Add"
        case 75: return "Divide"
        case 78: return "Subtract"
        case 81: return "="
        default: return nil
        }
    }
}
