//
//  NotchGeometry.swift
//  ClaudeIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: self.screenRect.midX - self.deviceNotchRect.width / 2,
            y: self.screenRect.maxY - self.deviceNotchRect.height,
            width: self.deviceNotchRect.width,
            height: self.deviceNotchRect.height,
        )
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        // Must stay in sync with NotchViewController.hitTestRect for .opened state
        let panelWidth = size.width + 52 // Account for corner radius padding
        let panelHeight = size.height
        return CGRect(
            x: self.screenRect.midX - panelWidth / 2,
            y: self.screenRect.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight,
        )
    }

    /// Check if a point is in the notch area (with padding for easier interaction)
    @inline(always)
    func isPointInNotch(_ point: CGPoint) -> Bool {
        self.notchScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        self.openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    @inline(always)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !self.openedScreenRect(for: size).contains(point)
    }
}
