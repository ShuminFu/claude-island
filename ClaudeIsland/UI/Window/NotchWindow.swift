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
    /// When false, ignoresMouseEvents should stay true so the transparent window
    /// doesn't interfere with mouse tracking at the .mainMenu+3 level.
    var isContentActive = false

    /// Optional claim hook for mouseDown events. Returns true if the given window-coordinate
    /// point should be treated as "owned by us" even when `contentView.hitTest` returns nil.
    ///
    /// Used by NotchWindowController to let drag-to-detach work across the full header
    /// rectangle — not just the rounded NotchShape. Without this, a click that lands in the
    /// rounded-corner cutouts (inside the header rect but outside the shape) fails `hitTest`,
    /// falls into the repost branch in `sendEvent`, and `CGEvent(mouseCursorPosition:)` warps
    /// the hardware cursor on every subsequent drag event — the classic "cursor pinned at
    /// the very top of the screen, drag twitches, nothing moves" failure mode.
    var shouldClaimMouseDown: ((CGPoint) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        // When the notch is not the active content (closed, or detached into a
        // floating panel), skip the passthrough/repost branches entirely. Reposting
        // via `CGEvent(..., mouseCursorPosition:)` warps the hardware cursor as a
        // side effect, and if the overlay is still receiving tail events from a
        // drag that started on it (AppKit routes drag events to the window that
        // got mouseDown regardless of a mid-gesture `ignoresMouseEvents` flip),
        // the repost loop manifests as the cursor twitching/locking.
        guard self.isContentActive else {
            super.sendEvent(event)
            return
        }

        // Track whether the in-progress drag started inside our content. If it did,
        // we own the entire drag — even when the cursor wanders outside the notch
        // shape — and must NOT repost. Reposting via `mouseCursorPosition:` warps
        // the hardware cursor and creates a feedback loop that traps the mouse and
        // makes panel-detach drags jitter. The flag is set on mouseDown and cleared
        // on the matching mouseUp.
        let isMouseDown = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
        let isMouseUp = event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp
        if isMouseDown {
            let locationInWindow = event.locationInWindow
            let screenLocation = self.convertPoint(toScreen: locationInWindow)
            // Accept either a SwiftUI hit-test match OR an explicit claim from the
            // window controller (e.g. a click in the drag-to-detach header rect that
            // lands on a rounded-corner cutout where the SwiftUI shape has no fill).
            let hitsContent = self.contentView?.hitTest(locationInWindow) != nil
            let claimed = self.shouldClaimMouseDown?(screenLocation) ?? false
            self.draggedFromContent = hitsContent || claimed
        }

        if self.draggedFromContent, Self.passthroughMouseTypes.contains(event.type) {
            super.sendEvent(event)
            if isMouseUp { self.draggedFromContent = false }
            return
        }
        if isMouseUp { self.draggedFromContent = false }

        // Mouse click, drag, and button events — pass through transparent areas
        if Self.passthroughMouseTypes.contains(event.type) {
            let locationInWindow = event.locationInWindow

            if let contentView,
               contentView.hitTest(locationInWindow) == nil {
                // No view wants this event — pass it through to windows behind.
                let screenLocation = convertPoint(toScreen: locationInWindow)
                self.repostMouseEvent(event, at: screenLocation)
                self.enablePassthroughBriefly()
                return
            }
        }

        // Scroll wheel events on transparent areas must also pass through,
        // otherwise the panel swallows scrolling in apps behind the overlay.
        if event.type == .scrollWheel {
            let locationInWindow = event.locationInWindow

            if let contentView,
               contentView.hitTest(locationInWindow) == nil {
                self.repostScrollEvent(event)
                self.enablePassthroughBriefly()
                return
            }
        }

        super.sendEvent(event)
    }

    // MARK: Private

    // MARK: - Click-through for areas outside the panel content

    /// Event types that should pass through transparent areas to windows behind.
    private static let passthroughMouseTypes: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    /// Track whether we're in a passthrough window to avoid overlapping asyncAfter timers.
    private var passthroughActive = false

    /// True while a mouse drag that started inside the notch content is in progress.
    /// Set on mouseDown that hits non-nil contentView, cleared on the matching mouseUp.
    /// While set, sendEvent skips the cursor-warping repost path so panel-detach drags
    /// can move the cursor outside the notch shape without jittering.
    private var draggedFromContent = false

    /// Temporarily set ignoresMouseEvents so the reposted CGEvent reaches windows behind.
    /// Guards against overlapping timers from rapid successive events.
    private func enablePassthroughBriefly() {
        guard !self.passthroughActive else { return }
        self.passthroughActive = true
        self.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            // Only restore mouse events if the panel content is still active.
            // If the panel closed during the passthrough window, keep ignoring.
            self.ignoresMouseEvents = !self.isContentActive
            self.passthroughActive = false
        }
    }

    private func repostScrollEvent(_ event: NSEvent) {
        // Convert window location to CGEvent screen coordinates (Y from top)
        let screenLocation = convertPoint(toScreen: event.locationInWindow)
        guard let screen = NSScreen.main else { return }
        let cgPoint = CGPoint(x: screenLocation.x, y: screen.frame.height - screenLocation.y)

        if let cgEvent = CGEvent(source: nil) {
            cgEvent.type = .scrollWheel
            cgEvent.location = cgPoint
            // Pixel-based scrolling (continuous trackpad / high-res mouse)
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(event.scrollingDeltaY))
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(event.scrollingDeltaX))
            // Line-based scrolling (classic scroll wheel)
            cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(event.scrollingDeltaY))
            cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(event.scrollingDeltaX))
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private func repostMouseEvent(_ event: NSEvent, at screenLocation: NSPoint) {
        // Convert to CGEvent coordinate system (Y from top of screen)
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        let cgPoint = CGPoint(x: screenLocation.x, y: screenHeight - screenLocation.y)

        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown; mouseButton = .left
        case .leftMouseUp: mouseType = .leftMouseUp; mouseButton = .left
        case .leftMouseDragged: mouseType = .leftMouseDragged; mouseButton = .left
        case .rightMouseDown: mouseType = .rightMouseDown; mouseButton = .right
        case .rightMouseUp: mouseType = .rightMouseUp; mouseButton = .right
        case .rightMouseDragged: mouseType = .rightMouseDragged; mouseButton = .right
        case .otherMouseDown: mouseType = .otherMouseDown; mouseButton = .center
        case .otherMouseUp: mouseType = .otherMouseUp; mouseButton = .center
        case .otherMouseDragged: mouseType = .otherMouseDragged; mouseButton = .center
        default: return
        }

        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton,
        ) {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
            cgEvent.flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
