//
//  TerminalFocuser+Warp.swift
//  ClaudeIsland
//
//  Warp-specific tab focus path: OSC 777 `warp://cli-agent` + Shift+Cmd+G.
//  See docs/features/warp-cli-agent-notification.md.
//

import AppKit
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

        // 2. Activate Warp (idempotent — the click-to-notification path also does this).
        let warp = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable").first
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp").first
        if let warp {
            _ = warp.activate()
        } else {
            Self.warpLogger.warning("no running Warp instance found — keystroke will fall on whatever app is frontmost")
        }

        // Give Warp a moment to actually become frontmost before posting keys.
        try? await Task.sleep(for: .milliseconds(80))

        // 3. Synthesize Shift+Cmd+G → workspace:jump_to_latest_toast.
        let posted = self.postKeystroke(keyCode: 0x05 /* g */, flags: [.maskCommand, .maskShift])
        if !posted {
            Self.warpLogger.error("Shift+Cmd+G synthesis failed — Accessibility permission missing?")
        }

        return true
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
            return true
        } catch {
            Self.warpLogger.warning("emitWarpCLIAgentIdle: write failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Key synthesis

    /// Post a single Cmd/Shift/etc-modified key to the system event tap.
    /// Returns true when both keyDown and keyUp events were created and posted.
    @MainActor
    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Logger

    nonisolated static let warpLogger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "WarpCLIAgent",
    )
}
