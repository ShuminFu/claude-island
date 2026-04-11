//
//  DetachedPanel.swift
//  ClaudeIsland
//
//  Independent floating window for detached notch content
//

import AppKit
import SwiftUI

// MARK: - FirstMouseHostingView

/// NSHostingView subclass that accepts the first mouse click even when the window
/// isn't key. Without this, `.nonactivatingPanel` eats the first click to promote
/// the panel to key status, so SwiftUI Buttons (like the dock-back button) ignore
/// the first tap until the panel is already focused.
///
/// `acceptsFirstMouse` alone is not enough for SwiftUI `.onTapGesture` on content
/// rows (e.g. session list inside the detached panel) — the first click after
/// focusing another window is still swallowed by key promotion. To fix that we
/// install a tracking area and proactively promote the panel to key as soon as
/// the cursor enters its bounds, so by the time the user clicks the panel is
/// already key and the click reaches SwiftUI gestures normally.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in self.trackingAreas {
            self.removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        self.addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let window = self.window, !window.isKeyWindow {
            window.makeKey()
        }
    }
}

// MARK: - DetachedPanel

/// NSPanel subclass for the detached (floating) notch panel.
/// Simpler than NotchPanel — no transparent passthrough needed since
/// the entire window is opaque content.
class DetachedPanel: NSPanel {
    // MARK: Lifecycle

    override init(
        contentRect: NSRect,
        styleMask _: NSWindow.StyleMask,
        backing _: NSWindow.BackingStoreType,
        defer _: Bool,
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )

        // Floating panel behavior
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = false

        // Transparent window — SwiftUI content provides the black background
        self.isOpaque = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.backgroundColor = .clear

        // Shadow for floating appearance
        self.hasShadow = true

        // Drag is handled by NotchDragController (not isMovableByWindowBackground)
        // to enable magnetic snap-back detection and avoid intercepting button clicks
        self.isMovable = false
        self.isMovableByWindowBackground = false

        // Above normal windows but below the menu bar
        self.level = .floating

        // Visible on all spaces (follows user across Space switches), not in window cycling
        self.collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]

        self.acceptsMouseMovedEvents = true
        // Let Swift ARC manage lifecycle — owner explicitly sets detachedPanel = nil
        self.isReleasedWhenClosed = false
    }

    // MARK: Internal

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
