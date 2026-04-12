//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Uses @Observable for efficient property-level change tracking (macOS 14+).
//

import AppKit
import Foundation
import Observation

// MARK: - ClaudeSessionMonitor

/// Session monitor using modern @Observable macro for efficient SwiftUI updates.
/// Subscribes to SessionStore's AsyncStream to receive session state changes.
@Observable
final class ClaudeSessionMonitor {
    // MARK: Lifecycle

    init() {
        self.sessionsTask = Task(name: "sessions-stream") { [weak self] in
            let stream = SessionStore.shared.sessionsStream()
            for await sessions in stream {
                self?.updateFromSessions(sessions)
            }
        }

        InterruptWatcherManager.shared.onInterrupt = { sessionID in
            Task(name: "interrupt-detected") { @MainActor in
                await SessionStore.shared.process(.interruptDetected(sessionID: sessionID))
                InterruptWatcherManager.shared.stopWatching(sessionID: sessionID)
            }
        }
    }

    // MARK: Internal

    var instances: [SessionState] = []
    var pendingInstances: [SessionState] = []

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { event in
                // Route directly to SessionStore — no [weak self] so this handler
                // remains valid even if the ClaudeSessionMonitor that called
                // startMonitoring() is later deallocated (e.g. DetachedNotchView
                // closing after overwriting the handler registered by NotchView).
                Task(name: "hook-event") { @MainActor in
                    await SessionStore.shared.process(.hookReceived(event))

                    // Start/stop interrupt watcher
                    if event.sessionPhase == .processing {
                        InterruptWatcherManager.shared.startWatching(
                            sessionID: event.sessionID,
                            cwd: event.cwd,
                        )
                    }
                    if event.status == "ended" {
                        InterruptWatcherManager.shared.stopWatching(sessionID: event.sessionID)
                    }

                    // Cancel pending permissions when session stops or tool completes
                    if event.event == "Stop" {
                        HookSocketServer.shared.cancelPendingPermissions(sessionID: event.sessionID)
                    }
                    if event.event == "PostToolUse", let toolUseID = event.toolUseID {
                        HookSocketServer.shared.cancelPendingPermission(toolUseID: toolUseID)
                    }
                }
            },
            onPermissionFailure: { sessionID, toolUseID in
                Task(name: "permission-failure") { @MainActor in
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionID: sessionID, toolUseID: toolUseID),
                    )
                }
            },
        )

        // Start periodic session status check
        Task(name: "start-periodic-check") {
            await SessionStore.shared.startPeriodicStatusCheck()
        }
    }

    func stopMonitoring() {
        self.sessionsTask?.cancel()
        self.sessionsTask = nil
        HookSocketServer.shared.stop()

        // Stop periodic session status check
        Task(name: "stop-periodic-check") {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionID: String) {
        Task(name: "approve-permission") {
            guard let session = await SessionStore.shared.session(for: sessionID),
                  let permission = session.activePermission
            else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseID: permission.toolUseID,
                decision: "allow",
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionID: sessionID, toolUseID: permission.toolUseID),
            )
            await SessionStore.shared.process(.markAsRead(sessionID: sessionID))
        }
    }

    func denyPermission(sessionID: String, reason: String?) {
        Task(name: "deny-permission") {
            guard let session = await SessionStore.shared.session(for: sessionID),
                  let permission = session.activePermission
            else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseID: permission.toolUseID,
                decision: "deny",
                reason: reason,
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionID: sessionID, toolUseID: permission.toolUseID, reason: reason),
            )
            await SessionStore.shared.process(.markAsRead(sessionID: sessionID))
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionID: String) {
        Task(name: "archive-session") {
            await SessionStore.shared.process(.sessionEnded(sessionID: sessionID))
        }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionID: String, cwd: String) {
        Task(name: "load-history") {
            await SessionStore.shared.process(.loadHistory(sessionID: sessionID, cwd: cwd))
        }
    }

    // MARK: Private

    /// Task for sessions stream subscription
    @ObservationIgnored private var sessionsTask: Task<Void, Never>?

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        self.instances = sessions
        self.pendingInstances = sessions.filter(\.needsAttention)
    }
}
