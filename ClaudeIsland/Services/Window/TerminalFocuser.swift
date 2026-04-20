//
//  TerminalFocuser.swift
//  ClaudeIsland
//
//  Focuses terminal applications without requiring yabai
//

import AppKit
import ApplicationServices
import Foundation
import os

// MARK: - TerminalFocuser

/// Focuses terminal applications using NSRunningApplication.activate()
/// This provides a universal terminal focus feature that works without yabai.
///
/// - Important: All focus methods are async to avoid blocking the main thread.
///   The underlying `ProcessTreeBuilder.buildTree()` calls `ProcessExecutor.runSync`
///   which has a precondition that it must not run on the main thread.
struct TerminalFocuser: Sendable {
    // MARK: Lifecycle

    nonisolated private init() {}

    // MARK: Internal

    nonisolated static let shared = Self()

    /// Focus the terminal hosting the given Claude session.
    ///
    /// Dispatches between two strategies:
    ///   - **Warp**: writes an OSC 777 `warp://cli-agent` frame to the
    ///     session's TTY then synthesizes Shift+Cmd+G — Warp's built-in
    ///     `workspace:jump_to_latest_toast` selects the right tab.
    ///   - **Other terminals**: existing PID → process-tree → activate flow,
    ///     followed by an OSC 0 tab-title flash for visual orientation.
    ///
    /// Centralizes the logic that used to be duplicated across ChatView,
    /// ClaudeInstancesView, and NotchViewModel.
    ///
    /// - Returns: true when *some* activation succeeded (does not guarantee
    ///   the user is now staring at the right tab — for non-Warp terminals
    ///   that's beyond our control).
    @discardableResult
    func focus(session: SessionState) async -> Bool {
        // Resolve the host terminal first — needed both for Warp detection
        // and for the generic fallback path.
        let hostInfo: (terminalPID: Int, command: String)? = await Task.detached(
            name: "find-terminal-for-session",
            priority: .userInitiated,
        ) {
            let tree = ProcessTreeBuilder.shared.buildTree()
            if let pid = session.pid,
               let terminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: pid, tree: tree),
               let info = tree[terminalPID] {
                return (terminalPID, info.command)
            }
            // Fallback: scan for a Claude process with matching cwd.
            for (pid, info) in tree {
                guard info.command.lowercased().contains("claude") else { continue }
                guard ProcessTreeBuilder.shared.getWorkingDirectory(forPID: pid) == session.cwd else { continue }
                if let terminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: pid, tree: tree),
                   let terminalInfo = tree[terminalPID] {
                    return (terminalPID, terminalInfo.command)
                }
            }
            return nil
        }.value

        // Warp path: OSC 777 + Shift+Cmd+G goes to the specific tab.
        if let hostInfo, hostInfo.command.lowercased().contains("warp") {
            if let tty = session.terminalTTY ?? session.tty, !tty.isEmpty {
                return await self.jumpToWarpTab(
                    tty: tty,
                    sessionID: session.sessionID,
                    projectName: session.projectName,
                )
            }
            // Explicit diagnostic — previously this fell silently through to
            // the generic activate path and the user just saw "Warp came to
            // front on the wrong tab". Common causes: tmux detached session,
            // hook never fired for this session yet.
            Self.logger.warning(
                "Warp detected but no TTY (session=\(session.sessionID)) — falling back to activate-only",
            )
        }

        // Generic path: activate by PID, then flash the tab title for orientation.
        let activated: Bool
        if let hostInfo {
            activated = await MainActor.run {
                self.activateTerminal(terminalPID: hostInfo.terminalPID, command: hostInfo.command)
            }
        } else {
            activated = false
        }

        if activated, AppSettings.enableTabFlashOnFocus,
           let tty = session.terminalTTY ?? session.tty {
            await self.flashTabTitle(tty: tty, projectName: session.projectName)
        }

        return activated
    }

    /// Focus the terminal app for a given Claude PID
    /// - Parameter claudePID: The process ID of the Claude instance
    /// - Returns: true if the terminal was successfully focused
    func focusTerminal(forClaudePID claudePID: Int) async -> Bool {
        // Run blocking process tree operations off the main thread via detached task
        let result: (terminalPID: Int, command: String)? = await Task.detached(name: "find-terminal-pid", priority: .userInitiated) {
            let tree = ProcessTreeBuilder.shared.buildTree()

            guard let terminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: claudePID, tree: tree),
                  let terminalInfo = tree[terminalPID]
            else {
                return nil
            }

            return (terminalPID, terminalInfo.command)
        }.value

        guard let result else {
            Self.logger.debug("No terminal found for Claude PID \(claudePID)")
            return false
        }

        return await MainActor.run {
            self.activateTerminal(terminalPID: result.terminalPID, command: result.command)
        }
    }

    /// Focus the terminal app for a given working directory (fallback when no PID)
    /// - Parameter workingDirectory: The current working directory to match
    /// - Returns: true if a terminal was successfully focused
    func focusTerminal(forWorkingDirectory workingDirectory: String) async -> Bool {
        // Run blocking process tree operations off the main thread via detached task
        let result: (terminalPID: Int, command: String)? = await Task.detached(name: "find-terminal-cwd", priority: .userInitiated) {
            let tree = ProcessTreeBuilder.shared.buildTree()

            // Find Claude processes with matching cwd
            for (pid, info) in tree {
                guard info.command.lowercased().contains("claude") else { continue }
                guard let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPID: pid) else { continue }
                guard cwd == workingDirectory else { continue }

                // Found a Claude with matching cwd, find its terminal
                if let terminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: pid, tree: tree),
                   let terminalInfo = tree[terminalPID] {
                    return (terminalPID, terminalInfo.command)
                }
            }

            return nil
        }.value

        guard let result else {
            Self.logger.debug("No terminal found for working directory \(workingDirectory)")
            return false
        }

        return await MainActor.run {
            self.activateTerminal(terminalPID: result.terminalPID, command: result.command)
        }
    }

    /// Flash the terminal tab title to draw the user's attention.
    ///
    /// Writes OSC 0 escape sequences to the TTY to temporarily change the tab title
    /// to a visually distinct "pointing" pattern, then restores the normal title.
    ///
    /// - Parameters:
    ///   - tty: The TTY name without `/dev/` prefix (e.g., "ttys032")
    ///   - projectName: The project name to include in the title
    func flashTabTitle(tty: String, projectName: String) async {
        let ttyPath = "/dev/\(tty)"
        Self.logger.info("Flash tab title: tty=\(ttyPath), project=\(projectName)")
        guard let handle = FileHandle(forWritingAtPath: ttyPath) else {
            Self.logger.warning("Cannot open TTY for tab flash: \(ttyPath)")
            return
        }
        defer { handle.closeFile() }

        let flash = "\u{1b}]0;\u{1f449}\u{1f449}\u{1f449} Claude: \(projectName) \u{1f448}\u{1f448}\u{1f448}\u{07}"
        let normal = "\u{1b}]0;\u{1f916} Claude: \(projectName)\u{07}"

        // Flash 3 times: on-off-on-off-on-restore
        for _ in 0 ..< 3 {
            handle.write(Data(flash.utf8))
            try? await Task.sleep(for: .milliseconds(600))
            handle.write(Data(normal.utf8))
            try? await Task.sleep(for: .milliseconds(300))
        }
        Self.logger.info("Flash tab title completed")
    }

    // MARK: Private

    /// Logger for terminal focus operations
    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "TerminalFocuser")

    /// Activate a terminal app by PID and command
    /// - Parameters:
    ///   - terminalPID: The terminal's process ID
    ///   - command: The terminal's command/process name
    /// - Returns: true if the terminal was activated
    nonisolated private func activateTerminal(terminalPID: Int, command: String) -> Bool {
        // Try to get the running app directly by PID
        if let app = NSRunningApplication(processIdentifier: pid_t(terminalPID)) {
            if self.bringAppToFront(app) {
                Self.logger.debug("Activated terminal via PID: \(terminalPID)")
                return true
            }
        }

        // Fallback: find by bundle identifier matching command name
        if let app = self.findRunningTerminalApp(command: command) {
            if self.bringAppToFront(app) {
                Self.logger.debug("Activated terminal via bundle ID for command: \(command)")
                return true
            }
        }

        Self.logger.debug("Failed to activate terminal PID \(terminalPID) with command \(command)")
        return false
    }

    /// Bring an app fully to the front, including un-hiding it and restoring any
    /// windows the user has minimized to the Dock.
    ///
    /// `NSRunningApplication.activate()` alone only focuses the app's menu bar — it does
    /// NOT un-hide a hidden app (Cmd+H) and does NOT deminiaturize windows that live in
    /// the Dock. For Dock restoration we prefer `NSWorkspace.openApplication(at:)`, which
    /// mimics a Dock-icon click and reliably pulls minimized windows back out, then fall
    /// back to the Accessibility API for edge cases where the app exposes minimized
    /// windows via `kAXWindows`.
    nonisolated private func bringAppToFront(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? "?"
        Self.logger
            .info(
                "bringAppToFront: pid=\(pid), bundle=\(bundleID), isHidden=\(app.isHidden), isActive=\(app.isActive)",
            )

        if app.isHidden {
            app.unhide()
        }

        // Best-effort synchronous activate — gives us an immediate return value.
        let activated = app.activate()
        Self.logger.info("activate() returned \(activated) for pid \(pid)")

        // Synchronous AX pass (fast, handles the common case when the app exposes windows).
        self.deminiaturizeWindows(pid: pid)

        // Async Dock-click equivalent. This is what actually restores Warp/Terminal windows
        // that activate() leaves in the Dock. Fire-and-forget; the window pops out ~100ms later.
        if let bundleURL = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { runningApp, error in
                if let error {
                    Self.logger.error("openApplication failed for pid \(pid): \(error.localizedDescription)")
                    return
                }
                let resolvedPID = runningApp?.processIdentifier ?? pid
                Self.logger.info("openApplication completed for pid \(resolvedPID)")
                // Second AX pass in case openApplication exposed windows that weren't visible before.
                Task(name: "deminiaturize-after-open") { @MainActor in
                    Self.shared.deminiaturizeWindows(pid: resolvedPID)
                }
            }
        } else {
            Self.logger.warning("No bundleURL for pid \(pid); skipping openApplication fallback")
        }

        return activated || app.bundleURL != nil
    }

    /// Deminiaturize any minimized windows of the target app via the Accessibility API,
    /// set the app as frontmost, and raise the best-candidate window. Always raising
    /// handles multi-Space cases (AXRaise triggers a Space switch) and apps whose
    /// minimized state isn't exposed via `kAXMinimized`.
    nonisolated private func deminiaturizeWindows(pid: pid_t) {
        let axTrusted = AXIsProcessTrusted()
        let appElement = AXUIElementCreateApplication(pid)

        // Force the app to be frontmost at the AX level. activate() sometimes reports
        // success without actually making the target app frontmost (non-activating panels).
        let frontmostValue: CFBoolean = kCFBooleanTrue
        let frontmostResult = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, frontmostValue)
        if frontmostResult != .success {
            Self.logger.info("AX set frontmost failed for pid \(pid): \(frontmostResult.rawValue)")
        }

        var windowsRef: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard copyResult == .success, let windows = windowsRef as? [AXUIElement] else {
            Self.logger
                .info(
                    "AX windows unavailable for pid \(pid): result=\(copyResult.rawValue), trusted=\(axTrusted)",
                )
            return
        }

        Self.logger.info("AX found \(windows.count) window(s) for pid \(pid) (trusted=\(axTrusted))")

        var restoredWindow: AXUIElement?
        var minimizedCount = 0
        for (idx, window) in windows.enumerated() {
            self.logWindowDiagnostics(window: window, pid: pid, index: idx)

            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let isMinimized = minimizedRef as? Bool, isMinimized
            else { continue }
            minimizedCount += 1

            let falseValue: CFBoolean = kCFBooleanFalse
            let setResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, falseValue)
            if setResult == .success {
                if restoredWindow == nil { restoredWindow = window }
                Self.logger.info("Deminiaturized window \(idx) for pid \(pid)")
            } else {
                Self.logger.warning("Failed to deminiaturize window \(idx) for pid \(pid): \(setResult.rawValue)")
            }
        }

        Self.logger.info("pid \(pid): \(minimizedCount) minimized window(s) among \(windows.count) total")

        // Always raise a window — handles multi-Space (AXRaise switches Spaces) and
        // "hidden-behind-other-windows" cases that activate() alone cannot fix.
        let targetWindow = restoredWindow ?? self.resolveMainWindow(appElement: appElement) ?? windows.first
        if let window = targetWindow {
            let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            Self.logger.info("AXRaise for pid \(pid): \(raiseResult.rawValue)")
        }
    }

    /// Return the app's main window (`kAXMainWindowAttribute`) if available.
    nonisolated private func resolveMainWindow(appElement: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &ref)
        guard result == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return (ref as! AXUIElement) // swiftlint:disable:this force_cast
    }

    /// Log the role, subrole, title, position, and size of an AX window — useful when
    /// a window isn't appearing as expected and we need to know where AX thinks it is.
    nonisolated private func logWindowDiagnostics(window: AXUIElement, pid: pid_t, index: Int) {
        func stringAttr(_ attr: String) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attr as CFString, &ref) == .success else { return "?" }
            return (ref as? String) ?? "?"
        }

        let role = stringAttr(kAXRoleAttribute as String)
        let subrole = stringAttr(kAXSubroleAttribute as String)
        let title = stringAttr(kAXTitleAttribute as String)

        var position = CGPoint.zero
        var positionRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
           let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID() {
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position) // swiftlint:disable:this force_cast
        }

        var size = CGSize.zero
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) // swiftlint:disable:this force_cast
        }

        Self.logger
            .info(
                // swiftlint:disable:next line_length
                "pid \(pid) window[\(index)]: role=\(role), subrole=\(subrole), title='\(title)', pos=(\(Int(position.x)),\(Int(position.y))), size=\(Int(size.width))x\(Int(size.height))",
            )
    }

    /// Find a running terminal app by matching the command name to known bundle identifiers
    /// - Parameter command: The terminal process command/name
    /// - Returns: The NSRunningApplication if found
    nonisolated private func findRunningTerminalApp(command: String) -> NSRunningApplication? {
        let lowerCommand = command.lowercased()

        // Map common terminal names to bundle identifiers
        let bundleIDMapping: [(patterns: [String], bundleID: String)] = [
            (["terminal"], "com.apple.Terminal"),
            (["iterm"], "com.googlecode.iterm2"),
            (["ghostty"], "com.mitchellh.ghostty"),
            (["alacritty"], "org.alacritty"),
            (["kitty"], "net.kovidgoyal.kitty"),
            (["hyper"], "co.zeit.hyper"),
            (["warp"], "dev.warp.Warp-Stable"),
            (["wezterm"], "com.github.wez.wezterm"),
            // VS Code Insiders must come before generic "code" to avoid false matches
            (["code - insiders", "code-insiders"], "com.microsoft.VSCodeInsiders"),
            (["vscode", "code"], "com.microsoft.VSCode"),
            (["cursor"], "com.todesktop.230313mzl4w4u92"),
            (["windsurf"], "com.exafunction.windsurf"),
            (["zed"], "dev.zed.Zed"),
        ]

        for (patterns, bundleID) in bundleIDMapping where patterns.contains(where: { lowerCommand.contains($0) }) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }

        // Try all known terminal bundle IDs as last resort
        for bundleID in TerminalAppRegistry.bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }

        return nil
    }
}
