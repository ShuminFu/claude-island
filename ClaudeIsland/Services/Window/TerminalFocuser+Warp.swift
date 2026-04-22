//
//  TerminalFocuser+Warp.swift
//  ClaudeIsland
//
//  Warp-specific tab focus path: AX "Switch to Next Tab" menu walk.
//  See docs/features/warp-tab-jump-hardening.md.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

extension TerminalFocuser {
    // MARK: - Warp tab jump

    /// Jump to the Warp tab whose window title matches the session's project.
    ///
    /// Why this shape: the earlier OSC 777 + Shift+Cmd+G path only worked when
    /// the OSC was written by an in-pty process (the Python hook). External
    /// writes to `/dev/ttysNNN` from Claude Island's GUI process reach the pty
    /// at the byte level but Warp does not register them as CLI agent toasts,
    /// so `workspace:jump_to_latest_toast` had nothing new to jump to and
    /// landed on whatever tab produced the most recent real toast.
    ///
    /// Warp also exposes neither its tab bar nor per-tab AX windows — the
    /// terminal area is GPU-rendered. The only per-tab AX surface we have is
    /// the single AXWindow title, which reflects the currently selected tab.
    /// So we walk tabs via the "Switch to Next Tab" menu item (an AXMenuItem
    /// we *can* invoke) and stop when the window title matches the target.
    ///
    /// - Parameters:
    ///   - tty: Retained for logging + diagnostic parity with the old API.
    ///   - sessionID: Retained for logging.
    ///   - cwd: Currently unused; kept for API stability.
    ///   - projectName: The substring we search for in `AXWindow.title`.
    /// - Returns: `true` when a matching tab was reached.
    @MainActor
    @discardableResult
    func jumpToWarpTab(
        tty: String,
        sessionID: String,
        cwd: String,
        projectName: String,
    ) async -> Bool {
        _ = tty
        _ = cwd
        Self.warpLogger.info("jumpToWarpTab: session=\(sessionID) project=\(projectName)")

        guard AXIsProcessTrusted() else {
            Self.warpLogger.warning("jumpToWarpTab: AX not trusted — falling back to activate-only")
            AccessibilityPermissionManager.shared.surfaceForWarpJumpIfNeeded()
            _ = Self.findRunningWarp()?.activate()
            return false
        }

        guard let warp = Self.findRunningWarp() else {
            Self.warpLogger.warning("jumpToWarpTab: no running Warp — nothing to do")
            return false
        }
        _ = warp.activate()

        let becameFront = await self.waitForFrontmost(
            bundleIDs: Self.warpBundleIDs,
            timeout: .milliseconds(500),
        )
        if !becameFront {
            Self.warpLogger.warning("jumpToWarpTab: Warp did not become frontmost within 500ms — proceeding anyway")
        }

        let appElement = AXUIElementCreateApplication(warp.processIdentifier)
        guard let frontWindow = Self.axFrontWindow(app: appElement) else {
            Self.warpLogger.warning("jumpToWarpTab: could not read AXFocusedWindow")
            return false
        }

        // Already on the right tab? Fast-path.
        let startTitle = Self.axTitle(frontWindow) ?? ""
        if Self.titleMatches(startTitle, project: projectName) {
            Self.warpLogger.info("jumpToWarpTab: already on target tab \"\(startTitle)\"")
            return true
        }

        guard let nextTabItem = Self.axFindMenuItem(app: appElement, path: ["Tab", "Switch to Next Tab"]) else {
            Self.warpLogger.error("jumpToWarpTab: AX could not locate Tab > Switch to Next Tab")
            return false
        }

        // Cycle up to 20 tabs; stop early if title matches or we return to the
        // starting tab (meaning we've looped and no tab matches).
        let maxTabs = 20
        for step in 1...maxTabs {
            AXUIElementPerformAction(nextTabItem, kAXPressAction as CFString)
            // Warp updates AXWindow.title synchronously on tab switch, but
            // give the main thread a beat to repaint + commit the change.
            try? await Task.sleep(for: .milliseconds(25))
            let title = Self.axTitle(frontWindow) ?? ""
            if Self.titleMatches(title, project: projectName) {
                Self.warpLogger.info("jumpToWarpTab: matched tab \"\(title)\" after \(step) step(s)")
                return true
            }
            if step > 1, title == startTitle {
                Self.warpLogger.warning("jumpToWarpTab: cycled back to \"\(startTitle)\" without matching project=\(projectName)")
                return false
            }
        }

        Self.warpLogger.warning("jumpToWarpTab: gave up after \(maxTabs) steps, last title=\(Self.axTitle(frontWindow) ?? "")")
        return false
    }

    // MARK: - Title match

    /// True when `windowTitle` contains `projectName` as a substring.
    ///
    /// Warp's tab title for a Claude session looks like
    /// `"✳ Investigate color inconsistency between web and app"` during an
    /// active request and `"⏸ Claude: <projectName>"` when idle. Matching on
    /// the project substring covers the idle case directly; for active-request
    /// titles Warp derives them from the prompt rather than the project, so
    /// this fallback will miss — acceptable trade-off until Warp exposes more.
    nonisolated static func titleMatches(_ windowTitle: String, project: String) -> Bool {
        guard !project.isEmpty else { return false }
        return windowTitle.localizedCaseInsensitiveContains(project)
    }

    // MARK: - AX helpers

    nonisolated static func axTitle(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    nonisolated static func axFrontWindow(app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            return (value as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let arr = value as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    /// Walk the AX menu bar to find a nested AXMenuItem by title path.
    nonisolated static func axFindMenuItem(app: AXUIElement, path: [String]) -> AXUIElement? {
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barValue) == .success,
              let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else {
            return nil
        }
        // swiftlint:disable:next force_cast
        var current: AXUIElement = (barValue as! AXUIElement)
        for (index, segment) in path.enumerated() {
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else {
                return nil
            }
            // Menu bar items expose their items via a nested AXMenu child —
            // when not on the first segment (which is a top-level AXMenuBarItem
            // we look up by title directly), step into the AXMenu first.
            let pool: [AXUIElement]
            if index == 0 {
                pool = children
            } else if let menu = children.first(where: { axRole($0) == "AXMenu" }) {
                var subValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &subValue) == .success,
                      let subChildren = subValue as? [AXUIElement] else {
                    return nil
                }
                pool = subChildren
            } else {
                pool = children
            }
            guard let match = pool.first(where: { axTitle($0) == segment }) else {
                return nil
            }
            current = match
        }
        return current
    }

    nonisolated static func axRole(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return ""
        }
        return (value as? String) ?? ""
    }

    /// Locate whichever Warp variant is currently running.
    @MainActor
    static func findRunningWarp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable").first
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp").first
    }

    // MARK: - Frontmost polling

    @MainActor
    func waitForFrontmost(bundleIDs: [String], timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               bundleIDs.contains(current) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    // MARK: - Constants

    nonisolated static let warpBundleIDs = [
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
    ]

    // MARK: - Logger

    nonisolated static let warpLogger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "WarpCLIAgent",
    )
}
