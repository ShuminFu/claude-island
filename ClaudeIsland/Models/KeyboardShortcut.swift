//
//  KeyboardShortcut.swift
//  ClaudeIsland
//
//  Model for configurable global keyboard shortcut
//

import AppKit

// MARK: - GlobalKeyboardShortcut

/// Represents a global keyboard shortcut (modifier keys + key code)
struct GlobalKeyboardShortcut: Codable, Equatable, Sendable {
    // MARK: Internal

    /// Default shortcut: ⌥C (Option + C)
    static let `default` = Self(keyCode: 8, modifiers: NSEvent.ModifierFlags.option.rawValue)

    /// Hardware key code (UInt16 from NSEvent.keyCode)
    let keyCode: UInt16

    /// Raw value of NSEvent.ModifierFlags (masked to device-independent flags)
    let modifiers: UInt

    /// Human-readable display string (e.g. "⌥C")
    var displayString: String {
        var parts: [String] = []

        let flags = NSEvent.ModifierFlags(rawValue: self.modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        parts.append(Self.keyName(for: self.keyCode))

        return parts.joined()
    }

    /// Create from an NSEvent (used during recording)
    static func from(event: NSEvent) -> Self {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        return Self(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// Check if an NSEvent matches this shortcut
    func matches(_ event: NSEvent) -> Bool {
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcutModifiers = NSEvent.ModifierFlags(rawValue: self.modifiers).intersection(.deviceIndependentFlagsMask)
        return event.keyCode == self.keyCode && eventModifiers == shortcutModifiers
    }

    // MARK: Private

    // MARK: - Key Name Mapping

    /// Map key codes to readable names
    private static func keyName(for keyCode: UInt16) -> String {
        // Common key code mappings
        let specialKeys: [UInt16: String] = [
            // Letters (QWERTY layout)
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".",
            // Special keys
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            // Arrow keys
            123: "←", 124: "→", 125: "↓", 126: "↑",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]

        return specialKeys[keyCode] ?? "Key\(keyCode)"
    }
}
