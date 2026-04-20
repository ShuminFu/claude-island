//
//  TerminalFocuser+Warp.swift
//  ClaudeIsland
//
//  Warp-specific tab focus path: OSC 777 `warp://cli-agent` + Shift+Cmd+G.
//  See docs/features/warp-cli-agent-notification.md.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

extension TerminalFocuser {
    // MARK: - Warp tab jump

    /// Jump to the specific Warp tab that hosts the given Claude session.
    ///
    /// Mechanism:
    ///   1. Re-emit an `idle_prompt` OSC 777 frame to the target tab's TTY,
    ///      promoting it to "most recent agent event" in Warp's wakeable_tabs queue.
    ///   2. Activate Warp (NSRunningApplication.activate — required because
    ///      key synthesis only succeeds inside the target app's main loop).
    ///   3. Synthesize Shift+Cmd+G — Warp's built-in
    ///      `workspace:jump_to_latest_toast` shortcut, which calls
    ///      Warp's internal `focus_tab()` (selected_tab = N + window raise).
    ///
    /// Falls back gracefully:
    ///   - No TTY available → returns false (caller should fall back to the
    ///     generic activate-terminal path).
    ///   - No Accessibility permission → keystroke synthesis silently fails;
    ///     Warp is still activated so the user lands on *some* Warp tab.
    ///
    /// - Parameters:
    ///   - tty: TTY path, may include or omit the `/dev/` prefix.
    ///   - sessionID: Claude session UUID (Warp uses for correlation only).
    ///   - projectName: Used in the OSC payload's `project` field.
    /// - Returns: `true` when the OSC frame was written. The keystroke step
    ///   is best-effort — we cannot observe Warp's internal selection state.
    @MainActor
    @discardableResult
    func jumpToWarpTab(
        tty: String,
        sessionID: String,
        projectName: String,
    ) async -> Bool {
        let resolvedTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        Self.warpLogger.info("jumpToWarpTab: tty=\(resolvedTTY), session=\(sessionID)")

        // 0. AX permission gate. CGEvent.post silently drops when untrusted —
        // bail before even trying the keystroke so we can surface the real
        // reason to the user instead of leaving them on an unrelated Warp tab.
        guard AXIsProcessTrusted() else {
            Self.warpLogger.warning("jumpToWarpTab: AX not trusted — falling back to activate-only")
            AccessibilityPermissionManager.shared.surfaceForWarpJumpIfNeeded()
            _ = Self.findRunningWarp()?.activate()
            return false
        }

        // 1. Re-emit idle_prompt so the target tab becomes the latest agent toast.
        let emitted = self.emitWarpCLIAgentIdle(
            ttyPath: resolvedTTY,
            sessionID: sessionID,
            projectName: projectName,
        )
        guard emitted else {
            Self.warpLogger.warning("emit failed for \(resolvedTTY) — aborting jump")
            return false
        }

        // Tiny delay so Warp's pty reader picks up the frame before the
        // keystroke arrives. Warp processes both on its main thread; ordering
        // matters for the wakeable_tabs queue update to land first.
        try? await Task.sleep(for: .milliseconds(50))

        Self.warpLogger.info("jumpToWarpTab: OSC emit ok, activating Warp")

        // 2. Activate Warp (idempotent — the click-to-notification path also does this).
        let warp = Self.findRunningWarp()
        if let warp {
            _ = warp.activate()
        } else {
            Self.warpLogger.warning("no running Warp instance found — keystroke will fall on whatever app is frontmost")
        }

        // Wait for Warp to actually become frontmost. From a non-activating
        // NSPanel (our notch) Warp usually stays frontmost the whole time —
        // this returns in ~1ms on the happy path — but the poll still guards
        // the edge case where Island steals focus or Warp is occluded.
        let becameFront = await self.waitForFrontmost(
            bundleIDs: Self.warpBundleIDs,
            timeout: .milliseconds(500),
        )
        let warpPID = warp?.processIdentifier
        Self.warpLogger.info(
            "jumpToWarpTab: waitForFrontmost=\(becameFront) pid=\(warpPID ?? -1)",
        )
        if !becameFront {
            let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            Self.warpLogger.warning(
                "jumpToWarpTab: Warp did not become frontmost within 500ms (current=\(current)) — posting keystroke anyway",
            )
        }

        // 3. Deliver Shift+Cmd+G directly to Warp's process.
        //
        // CGEvent.post(tap: .cghidEventTap) goes through the global HID queue
        // and was observed to land nowhere when triggered from our non-
        // activating notch panel (every log step succeeded but Warp didn't
        // react). CGEventPostToPid routes the key straight into Warp and
        // bypasses whatever is swallowing the global-tap path.
        let posted = await self.sendJumpToLatestToast(targetPID: warpPID)
        Self.warpLogger.info("jumpToWarpTab: sendJumpToLatestToast=\(posted)")
        if !posted {
            Self.warpLogger.error("Shift+Cmd+G synthesis failed via all paths")
        }

        return posted
    }

    /// Locate whichever Warp variant is currently running.
    @MainActor
    private static func findRunningWarp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable").first
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp").first
    }

    // MARK: - Frontmost polling

    /// Poll `NSWorkspace.shared.frontmostApplication` until one of the given
    /// bundle IDs is frontmost or the timeout elapses.
    ///
    /// `NSRunningApplication.activate()` is async at the WindowServer level —
    /// blindly sleeping a fixed interval is either too short (Warp not yet
    /// frontmost → keystroke lands on whatever was before) or too long
    /// (perceivable lag). Polling gives us both a tight happy-path and an
    /// observable slow-path.
    @MainActor
    private func waitForFrontmost(bundleIDs: [String], timeout: Duration) async -> Bool {
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

    // MARK: - OSC 777 emitter (Swift side)

    /// Write an `idle_prompt` OSC 777 frame to a Warp tab's TTY.
    ///
    /// This intentionally mirrors the Python `emit_warp_cli_agent_event`
    /// frame format. We do *not* read the Swift-side notification mode here —
    /// `jumpToWarpTab` is a user-initiated action ("focus this tab"), so the
    /// Phase 3 mode opt-out doesn't apply. The hook-side opt-out only governs
    /// passive emission during normal session activity.
    @MainActor
    private func emitWarpCLIAgentIdle(
        ttyPath: String,
        sessionID: String,
        projectName: String,
    ) -> Bool {
        let payload: [String: Any] = [
            "v": 1,
            "agent": "claude",
            "event": "idle_prompt",
            "session_id": sessionID,
            "project": projectName,
            "summary": "Focus requested from Claude Island",
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let body = String(data: bodyData, encoding: .utf8)
        else {
            Self.warpLogger.error("emitWarpCLIAgentIdle: failed to serialize payload")
            return false
        }

        let frame = "\u{1b}]777;notify;warp://cli-agent;\(body)\u{07}"

        guard let handle = FileHandle(forWritingAtPath: ttyPath) else {
            Self.warpLogger.warning("emitWarpCLIAgentIdle: cannot open \(ttyPath) for write")
            return false
        }
        defer { handle.closeFile() }

        do {
            try handle.write(contentsOf: Data(frame.utf8))
            Self.warpLogger.info("emitWarpCLIAgentIdle: wrote \(frame.utf8.count) bytes to \(ttyPath)")
            return true
        } catch {
            Self.warpLogger.warning("emitWarpCLIAgentIdle: write failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Key synthesis

    /// Send Warp's "jump to latest toast" shortcut (Shift+Cmd+G).
    ///
    /// Tries progressively less invasive paths:
    ///   1. `CGEventPostToPid(targetPID, …)` — delivers the key straight into
    ///      Warp's process, skipping the global HID queue that was observed
    ///      to silently swallow events fired from our non-activating notch.
    ///   2. Global `.cghidEventTap` post — legacy path, retained as a fallback
    ///      when the PID is unknown or the pid-targeted call fails.
    ///   3. NSAppleScript via System Events — survives some AX configurations
    ///      where the CGEvent bridge misbehaves.
    @MainActor
    private func sendJumpToLatestToast(targetPID: pid_t?) async -> Bool {
        if let targetPID, self.postKeystroke(keyCode: 0x05, flags: [.maskCommand, .maskShift], targetPID: targetPID) {
            return true
        }
        if self.postKeystroke(keyCode: 0x05, flags: [.maskCommand, .maskShift], targetPID: nil) {
            return true
        }
        Self.warpLogger.warning("CGEvent keystroke failed — falling back to AppleScript")
        return await Self.postKeystrokeViaAppleScript()
    }

    /// Post a single modified key either to `targetPID` (via `CGEventPostToPid`)
    /// or to the global HID event tap when `targetPID` is nil.
    /// Returns true when both keyDown and keyUp events were created and posted.
    @MainActor
    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags, targetPID: pid_t?) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = flags
        up.flags = flags
        if let targetPID {
            down.postToPid(targetPID)
            up.postToPid(targetPID)
            Self.warpLogger.info("postKeystroke: delivered Shift+Cmd+G to pid \(targetPID)")
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Backup keystroke path via System Events. Requires the same
    /// Accessibility permission as CGEvent but uses a different code path
    /// that sometimes survives when CGEvent creation returns nil.
    nonisolated private static func postKeystrokeViaAppleScript() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let source = """
            tell application "System Events" to keystroke "g" using {command down, shift down}
            """
            var err: NSDictionary?
            let script = NSAppleScript(source: source)
            _ = script?.executeAndReturnError(&err)
            if let err {
                Self.warpLogger.warning("AppleScript keystroke failed: \(err)")
                return false
            }
            return true
        }.value
    }

    // MARK: - Constants

    /// Bundle IDs for every Warp variant we recognise as frontmost.
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
