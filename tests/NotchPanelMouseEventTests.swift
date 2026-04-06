//
//  NotchPanelMouseEventTests.swift
//  ClaudeIslandTests
//
//  Tests for NotchPanel mouse event handling on notch vs non-notch screens
//

import AppKit
import Testing

@testable import Claude_Island

// MARK: - Click Interceptor Panel Tests

@MainActor
@Suite("Click interceptor panel for non-notch screens")
struct ClickInterceptorTests {
    @Test("Interceptor panel is created on non-notch screen")
    func interceptorCreatedOnNonNotchScreen() {
        guard let screen = NSScreen.main else {
            Issue.record("No main screen available")
            return
        }

        let controller = NotchWindowController(screen: screen, animateOnLaunch: false)

        if screen.hasPhysicalNotch {
            // On notch screens, no interceptor needed
            #expect(controller.hasClickInterceptor == false)
        } else {
            // On non-notch screens, interceptor should be created
            #expect(controller.hasClickInterceptor == true)
        }
    }

    @Test("Interceptor panel covers the notch rect area")
    func interceptorCoversNotchRect() {
        guard let screen = NSScreen.main, !screen.hasPhysicalNotch else {
            // Skip on notch screens
            return
        }

        let controller = NotchWindowController(screen: screen, animateOnLaunch: false)
        let notchRect = controller.viewModel.geometry.notchScreenRect

        guard let interceptFrame = controller.clickInterceptorFrame else {
            Issue.record("Click interceptor should exist on non-notch screen")
            return
        }

        // Interceptor should contain the notch rect (with padding)
        #expect(interceptFrame.contains(CGPoint(x: notchRect.midX, y: notchRect.midY)))
    }

    @Test("Interceptor panel accepts mouse events")
    func interceptorAcceptsMouseEvents() {
        guard let screen = NSScreen.main, !screen.hasPhysicalNotch else {
            return
        }

        let controller = NotchWindowController(screen: screen, animateOnLaunch: false)
        #expect(controller.clickInterceptorIgnoresMouseEvents == false)
    }

    @Test("Interceptor panel is above the main panel")
    func interceptorAboveMainPanel() {
        guard let screen = NSScreen.main, !screen.hasPhysicalNotch else {
            return
        }

        let controller = NotchWindowController(screen: screen, animateOnLaunch: false)
        let mainLevel = controller.window?.level ?? .normal
        let interceptLevel = controller.clickInterceptorLevel ?? .normal

        #expect(interceptLevel.rawValue > mainLevel.rawValue)
    }
}

// MARK: - NotchGeometry Hit Test Tests

@Suite("NotchGeometry hit testing")
struct NotchGeometryHitTestTests {
    /// Standard geometry: 1920x1080 screen, 224x38 notch centered
    static let standardGeometry = NotchGeometry(
        deviceNotchRect: CGRect(x: (1920 - 224) / 2, y: 0, width: 224, height: 38),
        screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        windowHeight: 750
    )

    @Test("notchScreenRect is centered at top of screen")
    func notchScreenRectPosition() {
        let geo = Self.standardGeometry
        let rect = geo.notchScreenRect

        #expect(rect.midX == 1920.0 / 2)
        #expect(rect.maxY == 1080.0)
        #expect(rect.width == 224.0)
        #expect(rect.height == 38.0)
    }

    @Test("isPointInNotch returns true for point at center of notch")
    func pointInNotchCenter() {
        let geo = Self.standardGeometry
        let center = CGPoint(x: 1920.0 / 2, y: 1080.0 - 19.0)
        #expect(geo.isPointInNotch(center) == true)
    }

    @Test("isPointInNotch returns false for point far from notch")
    func pointFarFromNotch() {
        let geo = Self.standardGeometry
        let farPoint = CGPoint(x: 100, y: 500)
        #expect(geo.isPointInNotch(farPoint) == false)
    }

    @Test("isPointInNotch includes padding for easier interaction")
    func pointInNotchPadding() {
        let geo = Self.standardGeometry
        let notchRect = geo.notchScreenRect
        let pointJustOutside = CGPoint(x: notchRect.minX - 5, y: notchRect.midY)
        #expect(geo.isPointInNotch(pointJustOutside) == true)
    }

    @Test("isPointInNotch returns false for point on menu bar left side")
    func pointOnMenuBarLeft() {
        let geo = Self.standardGeometry
        let menuBarPoint = CGPoint(x: 100, y: 1080.0 - 12.0)
        #expect(geo.isPointInNotch(menuBarPoint) == false)
    }

    @Test("isPointInNotch returns false for point on menu bar right side")
    func pointOnMenuBarRight() {
        let geo = Self.standardGeometry
        let menuBarPoint = CGPoint(x: 1800, y: 1080.0 - 12.0)
        #expect(geo.isPointInNotch(menuBarPoint) == false)
    }

    @Test("openedScreenRect is centered and anchored to top")
    func openedScreenRectPosition() {
        let geo = Self.standardGeometry
        let size = CGSize(width: 480, height: 320)
        let rect = geo.openedScreenRect(for: size)

        #expect(rect.midX == 1920.0 / 2)
        #expect(rect.maxY == 1080.0)
    }

    @Test("isPointOutsidePanel returns true for point outside opened panel")
    func pointOutsideOpenedPanel() {
        let geo = Self.standardGeometry
        let size = CGSize(width: 480, height: 320)
        let outsidePoint = CGPoint(x: 100, y: 500)
        #expect(geo.isPointOutsidePanel(outsidePoint, size: size) == true)
    }

    @Test("isPointOutsidePanel returns false for point inside opened panel")
    func pointInsideOpenedPanel() {
        let geo = Self.standardGeometry
        let size = CGSize(width: 480, height: 320)
        let rect = geo.openedScreenRect(for: size)
        let insidePoint = CGPoint(x: rect.midX, y: rect.midY)
        #expect(geo.isPointOutsidePanel(insidePoint, size: size) == false)
    }
}

// MARK: - NSScreen Notch Size Tests

@Suite("NSScreen notch size fallback")
struct NSScreenNotchSizeTests {
    @Test("Non-notch screen returns fallback notch size")
    func fallbackNotchSize() {
        guard let screen = NSScreen.main else {
            Issue.record("No main screen available")
            return
        }

        if !screen.hasPhysicalNotch {
            let size = screen.notchSize
            #expect(size.width == 224)
            #expect(size.height == 38)
        }
    }

    @Test("hasPhysicalNotch matches safeAreaInsets check")
    func hasPhysicalNotchConsistency() {
        guard let screen = NSScreen.main else {
            Issue.record("No main screen available")
            return
        }
        #expect(screen.hasPhysicalNotch == (screen.safeAreaInsets.top > 0))
    }
}
