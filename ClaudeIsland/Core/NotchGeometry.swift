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
    // MARK: - Magnetic Snap

    /// Magnetic snap radius in points
    static let snapRadius: CGFloat = 120

    let deviceNotchRect: CGRect
    let screenRect: CGRect

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: self.screenRect.midX - self.deviceNotchRect.width / 2,
            y: self.screenRect.maxY - self.deviceNotchRect.height,
            width: self.deviceNotchRect.width,
            height: self.deviceNotchRect.height,
        )
    }

    /// The center of the notch in screen coordinates
    var notchCenter: CGPoint {
        CGPoint(x: self.notchScreenRect.midX, y: self.notchScreenRect.midY)
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
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

    /// Check if a point is in the opened panel area.
    ///
    /// Uses an inclusive bounds check instead of `CGRect.contains` so that a cursor flush
    /// against the very top of the screen (`y == panelRect.maxY`, where macOS clamps the
    /// pointer) still counts as inside the panel. `CGRect.contains` uses a half-open
    /// interval on `maxY` and would otherwise treat the topmost row as outside — which
    /// caused the notch to auto-close mid-drag and abort `beginDetach()`.
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        let rect = self.openedScreenRect(for: size)
        return point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// Check if a point is outside the opened panel (for closing)
    @inline(always)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !self.isPointInOpenedPanel(point, size: size)
    }

    /// Distance from a screen-coordinate point to the notch center
    func distanceToNotchCenter(_ point: CGPoint) -> CGFloat {
        let dx = point.x - self.notchCenter.x
        let dy = point.y - self.notchCenter.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Whether a screen-coordinate point is within the magnetic snap radius
    @inline(always)
    func isInSnapZone(_ point: CGPoint) -> Bool {
        self.distanceToNotchCenter(point) < Self.snapRadius
    }
}
