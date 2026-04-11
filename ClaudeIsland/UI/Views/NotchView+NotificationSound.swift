//
//  NotchView+NotificationSound.swift
//  ClaudeIsland
//
//  Notification sound suppression logic extracted from NotchView
//

import AppKit

extension NotchView {
    /// Determine if notification sound should play for the given sessions
    /// Returns true if sound should play based on suppression settings
    func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        let suppressionMode = AppSettings.soundSuppression

        // If suppression is disabled, always play sound
        if suppressionMode == .never {
            return true
        }

        // Suppress if Claude Island is active
        if NSApplication.shared.isActive {
            return false
        }

        // Check each session against the suppression mode
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus/visibility, assume should play
                return true
            }

            switch suppressionMode {
            case .never:
                return true

            case .whenFocused:
                let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPID: pid)
                if !isFocused {
                    return true
                }

            case .whenVisible:
                let isVisible = await TerminalVisibilityDetector.isSessionTerminalVisible(sessionPID: pid)
                if !isVisible {
                    return true
                }
            }
        }

        return false
    }
}
