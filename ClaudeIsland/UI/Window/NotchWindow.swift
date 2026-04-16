//
//  NotchWindow.swift
//  ClaudeIsland
//
//  Transparent window that overlays the notch area.
//  When closed: ignores all mouse events (global event monitors handle hover/click-to-open).
//  When open: resized to the visible content rect so clicks outside pass through natively.
//

import AppKit

/// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    // MARK: Lifecycle

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool,
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // Start ignoring mouse events — the notch begins closed.
        // NotchWindowController enables mouse events when the panel opens.
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    // MARK: Internal

    override var canBecomeKey: Bool {
        // Only accept key status when content is active — prevents the panel from
        // capturing keyboard/mouse focus when closed (window still covers screen top)
        self.isContentActive
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Whether the panel's content is actively shown (opened state).
    var isContentActive = false
}
