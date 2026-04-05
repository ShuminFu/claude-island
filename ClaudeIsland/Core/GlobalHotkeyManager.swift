//
//  GlobalHotkeyManager.swift
//  ClaudeIsland
//
//  Manages global keyboard shortcut for toggling the notch panel
//

import AppKit
import os

// MARK: - GlobalHotkeyManager

/// Manages global keyboard shortcut registration and event handling
@Observable
@MainActor
final class GlobalHotkeyManager {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = GlobalHotkeyManager()

    /// Whether the shortcut recorder is active (capturing next key combo)
    private(set) var isRecording = false

    /// Callback invoked when the hotkey is pressed
    var onToggle: (() -> Void)?

    /// Callback invoked when a new shortcut is recorded
    var onShortcutRecorded: ((GlobalKeyboardShortcut) -> Void)?

    /// Start monitoring for the global hotkey
    func start() {
        guard self.keyMonitor == nil else { return }

        self.keyMonitor = EventMonitor(mask: .keyDown) { [weak self] event in
            // Extract Sendable values from NSEvent before crossing isolation boundary
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let hasCharacters = event.charactersIgnoringModifiers != nil
            MainActor.assumeIsolated {
                self?.handleKeyEvent(keyCode: keyCode, modifiers: modifiers, hasCharacters: hasCharacters)
            }
        }
        self.keyMonitor?.start()
        Self.logger.debug("Global hotkey monitor started")
    }

    /// Stop monitoring
    func stop() {
        self.keyMonitor?.stop()
        self.keyMonitor = nil
        Self.logger.debug("Global hotkey monitor stopped")
    }

    /// Enter recording mode — next key combo will be captured as the new shortcut
    func startRecording() {
        self.isRecording = true
    }

    /// Exit recording mode without saving
    func stopRecording() {
        self.isRecording = false
    }

    // MARK: Private

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "GlobalHotkey")

    private var keyMonitor: EventMonitor?

    private func handleKeyEvent(keyCode: UInt16, modifiers: UInt, hasCharacters: Bool) {
        let eventShortcut = GlobalKeyboardShortcut(keyCode: keyCode, modifiers: modifiers)

        // Recording mode: capture the key combo
        if self.isRecording {
            // Ignore bare modifier key presses (no actual key)
            guard keyCode != 0 || hasCharacters else { return }

            // Require at least one modifier key
            guard modifiers != 0 else { return }

            AppSettings.globalHotkey = eventShortcut
            self.isRecording = false
            self.onShortcutRecorded?(eventShortcut)
            Self.logger.info("Recorded new hotkey: \(eventShortcut.displayString, privacy: .public)")
            return
        }

        // Normal mode: check if event matches the configured hotkey
        guard AppSettings.globalHotkeyEnabled,
              let shortcut = AppSettings.globalHotkey,
              shortcut == eventShortcut
        else {
            return
        }

        Self.logger.debug("Global hotkey triggered: \(shortcut.displayString, privacy: .public)")
        self.onToggle?()
    }
}
