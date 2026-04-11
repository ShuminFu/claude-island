//
//  NavigationKeymap.swift
//  ClaudeIsland
//
//  Configurable keyboard navigation following Apple's "negative one screen" spatial model.
//  Menu ←── Instances List ──→ Chat
//

import Foundation

// MARK: - NavigationAction

/// Spatial navigation actions for the notch panel.
/// Left/Right follow the screen hierarchy, Up/Down select within a view.
enum NavigationAction {
    /// Move selection up within current view
    case up
    /// Move selection down within current view
    case down
    /// Navigate left in hierarchy (chat→instances, instances→menu)
    case left
    /// Navigate right in hierarchy (menu→instances, instances→chat)
    case right
    /// Confirm/activate the current selection (same as right in instances)
    case confirm
    /// Close/go back one level (chat→instances, instances→close, menu→instances)
    case close
}

// MARK: - NavigationStyle

/// Available keyboard navigation styles
enum NavigationStyle: String, CaseIterable, Sendable {
    case arrows = "Arrows"
    case vim = "Vim"
    case both = "Both"
}

// MARK: - NavigationKeymap

/// Maps key codes to navigation actions based on the active style
struct NavigationKeymap: Sendable {
    // MARK: Internal

    /// Build a keymap for the given navigation style
    static func keymap(for style: NavigationStyle) -> Self {
        switch style {
        case .arrows:
            Self(mapping: self.arrowBindings)
        case .vim:
            Self(mapping: self.arrowBindings.merging(self.vimBindings) { _, vim in vim })
        case .both:
            Self(mapping: self.arrowBindings.merging(self.vimBindings) { arrow, _ in arrow })
        }
    }

    /// Resolve a key code to a navigation action, if any
    func action(for keyCode: UInt16) -> NavigationAction? {
        self.mapping[keyCode]
    }

    // MARK: Private

    /// Arrow key bindings
    private static let arrowBindings: [UInt16: NavigationAction] = [
        126: .up, // ↑
        125: .down, // ↓
        123: .left, // ←
        124: .right, // →
        36: .confirm, // Return
        53: .close, // Escape
    ]

    /// Vim key bindings
    private static let vimBindings: [UInt16: NavigationAction] = [
        40: .up, // k
        38: .down, // j
        4: .left, // h
        37: .right, // l
        36: .confirm, // Return
        53: .close, // Escape
        12: .close, // q
    ]

    private let mapping: [UInt16: NavigationAction]
}
