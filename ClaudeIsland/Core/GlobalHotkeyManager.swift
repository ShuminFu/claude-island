//
//  GlobalHotkeyManager.swift
//  ClaudeIsland
//
//  Manages global keyboard shortcut for toggling the notch panel
//

import AppKit
import Carbon.HIToolbox
import os

// MARK: - GlobalHotkeyManager

/// Manages global keyboard shortcut registration and event handling.
///
/// Uses Carbon's `RegisterEventHotKey` API for the active shortcut so the key is
/// genuinely consumed at the window-server level and never leaks into the focused
/// app's text field. Recording mode uses a local `NSEvent` monitor, which is safe
/// because the settings panel is already key when the user clicks "Record".
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

    /// Register the current hotkey and install the Carbon event handler.
    func start() {
        self.installEventHandlerIfNeeded()
        self.registerCurrentHotkey()
    }

    /// Unregister the active hotkey and cancel any in-progress recording.
    func stop() {
        self.unregisterCurrentHotkey()
        self.stopRecording()
    }

    /// Re-read `AppSettings` and re-register. Call after toggling enabled or resetting.
    func refresh() {
        self.unregisterCurrentHotkey()
        self.registerCurrentHotkey()
    }

    /// Enter recording mode — next key combo will be captured as the new shortcut.
    /// While recording, the active Carbon hotkey is temporarily unregistered so the
    /// user can re-bind the same combo.
    func startRecording() {
        guard !self.isRecording else { return }
        self.isRecording = true
        self.unregisterCurrentHotkey()

        self.recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            // addLocalMonitorForEvents' handler is already @MainActor in modern SDK,
            // so we can call main-actor-isolated methods directly.
            guard let self else { return event }
            return self.handleRecordingEvent(event)
        }
    }

    /// Exit recording mode without saving and re-register the previously active hotkey.
    func stopRecording() {
        if let monitor = self.recordingMonitor {
            NSEvent.removeMonitor(monitor)
            self.recordingMonitor = nil
        }
        guard self.isRecording else { return }
        self.isRecording = false
        self.registerCurrentHotkey()
    }

    // MARK: Private

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "GlobalHotkey")

    /// Four-char signature identifying hotkeys owned by this app ('ciHK').
    private static let hotKeySignature: OSType = {
        var code: OSType = 0
        for byte in "ciHK".utf8 {
            code = (code << 8) | OSType(byte)
        }
        return code
    }()

    /// Numeric ID assigned to our single registered hotkey.
    private static let hotKeyID: UInt32 = 1

    /// C-convention event handler invoked by Carbon when the hotkey fires.
    /// Runs on the main thread because `GetApplicationEventTarget()` is pumped by the
    /// main run loop, so we can dynamically assume main-actor isolation.
    private static let eventHandlerCallback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated {
            manager.onToggle?()
        }
        return noErr
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var recordingMonitor: Any?

    /// Translate `NSEvent.ModifierFlags` raw value to Carbon modifier flags.
    private static func carbonModifiers(from nsModifiers: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: nsModifiers)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Install the Carbon event handler once. The handler stays resident for the
    /// lifetime of the process — registering a new hotkey later just swaps the
    /// `EventHotKeyRef` while the handler keeps dispatching to `onToggle`.
    private func installEventHandlerIfNeeded() {
        guard self.eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventType,
            selfPtr,
            &self.eventHandlerRef,
        )
        if status != noErr {
            Self.logger.error("InstallEventHandler failed with status \(status)")
        }
    }

    private func registerCurrentHotkey() {
        guard AppSettings.globalHotkeyEnabled,
              let shortcut = AppSettings.globalHotkey
        else { return }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref,
        )
        if status == noErr {
            self.hotKeyRef = ref
            Self.logger.info("Registered Carbon hotkey: \(shortcut.displayString, privacy: .public)")
        } else {
            Self.logger.error("RegisterEventHotKey failed with status \(status)")
        }
    }

    private func unregisterCurrentHotkey() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        self.hotKeyRef = nil
    }

    /// Handle a keyDown event while in recording mode. Returns `nil` to swallow
    /// the event so the captured chord doesn't leak into whatever view is focused.
    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let hasCharacters = event.charactersIgnoringModifiers != nil

        // Ignore bare modifier key presses (no actual key)
        guard keyCode != 0 || hasCharacters else { return event }

        // Require at least one modifier key
        guard modifiers != 0 else { return event }

        let shortcut = GlobalKeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        AppSettings.globalHotkey = shortcut
        self.stopRecording() // re-registers the new hotkey
        self.onShortcutRecorded?(shortcut)
        Self.logger.info("Recorded new hotkey: \(shortcut.displayString, privacy: .public)")
        return nil
    }
}
