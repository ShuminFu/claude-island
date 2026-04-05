//
//  NotchWindow.swift
//  ClaudeIsland
//
//  Transparent window that overlays the notch area
//  Following NotchDrop's approach: window ignores mouse events,
//  we use global event monitors to detect clicks/hovers
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

        // Mouse events are always accepted. Per-pixel transparency (isOpaque = false
        // + backgroundColor = .clear) ensures clicks on transparent areas pass through
        // to the menu bar / windows behind. sendEvent handles edge cases via repost.
        ignoresMouseEvents = false

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    // MARK: Internal

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    // MARK: - Click-through for areas outside the panel content

    override func sendEvent(_ event: NSEvent) {
        // For mouse events, check if we should pass through
        if event.type == .leftMouseDown || event.type == .leftMouseUp ||
            event.type == .rightMouseDown || event.type == .rightMouseUp {
            // Get the location in window coordinates
            let locationInWindow = event.locationInWindow

            // Check if any view wants to handle this event
            if let contentView,
               contentView.hitTest(locationInWindow) == nil {
                // No view wants this event — pass it through to windows behind.
                // Temporarily ignore mouse events so the reposted CGEvent reaches
                // the window behind us, then re-enable so we keep intercepting.
                let screenLocation = convertPoint(toScreen: locationInWindow)
                ignoresMouseEvents = true
                self.repostMouseEvent(event, at: screenLocation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.ignoresMouseEvents = false
                }
                return
            }
        }

        super.sendEvent(event)
    }

    // MARK: Private

    private func repostMouseEvent(_ event: NSEvent, at screenLocation: NSPoint) {
        // Convert to CGEvent coordinate system (Y from top of screen)
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        let cgPoint = CGPoint(x: screenLocation.x, y: screenHeight - screenLocation.y)

        let mouseType: CGEventType
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown
        case .leftMouseUp: mouseType = .leftMouseUp
        case .rightMouseDown: mouseType = .rightMouseDown
        case .rightMouseUp: mouseType = .rightMouseUp
        default: return
        }

        let mouseButton: CGMouseButton = event.type == .rightMouseDown || event.type == .rightMouseUp ? .right : .left

        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton,
        ) {
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
