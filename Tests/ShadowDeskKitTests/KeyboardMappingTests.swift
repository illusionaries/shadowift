import Foundation
import Testing

@testable import ShadowDeskKit

@Suite("Keyboard event mapping")
struct KeyboardMappingTests {
    private func name(
        _ keyCode: UInt16,
        characters: String?,
        ignoring: String? = nil,
        modifiers: KeyboardMapping.Modifiers = []
    ) -> String? {
        KeyboardMapping.keyName(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            modifiers: modifiers
        )
    }

    @Test("plain printable keys pass through")
    func plainKeys() {
        #expect(name(0, characters: "a") == "a")
        #expect(name(0, characters: "A", modifiers: .shift) == "A")
        #expect(name(18, characters: "1") == "1")
        #expect(name(18, characters: "!", modifiers: .shift) == "!")
        #expect(name(49, characters: " ") == " ")
    }

    @Test("control combinations use the base key (Ctrl+C is 0x03 in AppKit)")
    func controlCombinations() {
        // AppKit reports Ctrl+C as an ETX control character; browsers report "c".
        #expect(name(8, characters: "\u{03}", ignoring: "c", modifiers: .control) == "c")
        #expect(name(0, characters: "\u{01}", ignoring: "a", modifiers: .control) == "a")
        #expect(name(0, characters: "\u{01}", ignoring: "A", modifiers: [.control, .shift]) == "A")
        // Even without the modifier flag, a control character must not leak out.
        #expect(name(8, characters: "\u{03}", ignoring: "c") == "c")
        #expect(name(8, characters: "\u{03}", ignoring: nil) == nil)
    }

    @Test("command combinations use the base key")
    func commandCombinations() {
        #expect(name(8, characters: "c", ignoring: "c", modifiers: .command) == "c")
        #expect(name(8, characters: "ç", ignoring: "c", modifiers: [.command, .option]) == "c")
    }

    @Test("option combinations keep the base key so the agent sees Alt+key")
    func optionCombinations() {
        #expect(name(0, characters: "å", ignoring: "a", modifiers: .option) == "a")
    }

    @Test("special keys and function keys")
    func specialKeys() {
        #expect(name(53, characters: "\u{1B}") == "Escape")
        #expect(name(36, characters: "\r") == "Enter")
        #expect(name(48, characters: "\t") == "Tab")
        #expect(name(51, characters: "\u{8}") == "Backspace")
        #expect(name(123, characters: nil) == "ArrowLeft")
        #expect(name(96, characters: nil) == "F5")
        #expect(name(117, characters: nil) == "Delete")
    }

    @Test("numpad keys report their names")
    func numpad() {
        #expect(name(83, characters: "1") == "1")
        #expect(name(82, characters: "0") == "0")
        #expect(name(65, characters: ".") == "Decimal")
        #expect(name(69, characters: "+") == "Add")
    }

    @Test("modifier keys are named and their state is tracked")
    func modifiers() {
        #expect(KeyboardMapping.modifierName(keyCode: 59) == "Control")
        #expect(KeyboardMapping.modifierName(keyCode: 61) == "AltGraph")
        #expect(KeyboardMapping.isModifierDown(keyCode: 59, modifiers: .control))
        #expect(!KeyboardMapping.isModifierDown(keyCode: 59, modifiers: .shift))
        #expect(KeyboardMapping.isModifierDown(keyCode: 55, modifiers: .command))
    }

    /// The client releases a modifier on focus loss by replaying its key-up,
    /// using the key code it recorded when forwarding the press. Every code it
    /// can record therefore has to keep a name and map back to a flag.
    @Test("every trackable modifier key code releases cleanly")
    func modifierKeyCodesRoundTrip() {
        let expectations: [(UInt16, String, KeyboardMapping.Modifiers)] = [
            (55, "Meta", .command), (54, "Meta", .command),
            (56, "Shift", .shift), (60, "Shift", .shift),
            (59, "Control", .control), (62, "Control", .control),
            (58, "Alt", .option), (61, "AltGraph", .option),
            (57, "CapsLock", .capsLock),
        ]
        for (keyCode, expectedName, flag) in expectations {
            #expect(KeyboardMapping.modifierName(keyCode: keyCode) == expectedName)
            #expect(KeyboardMapping.isModifierDown(keyCode: keyCode, modifiers: flag))
            #expect(!KeyboardMapping.isModifierDown(keyCode: keyCode, modifiers: []))
        }
        // Fn is named but has no flag of its own, so it is never tracked.
        #expect(KeyboardMapping.modifierName(keyCode: 63) == "Fn")
        #expect(!KeyboardMapping.isModifierDown(keyCode: 63, modifiers: .function))
        // Non-modifier codes are ignored by the release path.
        #expect(KeyboardMapping.modifierName(keyCode: 0) == nil)
    }
}
