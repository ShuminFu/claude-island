//
//  SessionPhaseHelpers.swift
//  ClaudeIsland
//
//  Helper functions for session phase display
//

import Foundation
import SwiftUI

// MARK: - Instance Sorting

extension [SessionState] {
    /// Sorted by phase priority (active > waitingForInput > idle),
    /// then by last user message date (most recent first).
    ///
    /// Special case: `waitingForApproval` items are grouped to the front of their
    /// priority bucket and sorted by date only (ignoring `hasUnreadUpdate`). This
    /// keeps the list stable while the user hovers over approval rows — otherwise
    /// the hover-mark-read feature would push the hovered item behind other unread
    /// approval items and slide a different row under the cursor.
    func sortedByPriority() -> [SessionState] {
        self.sorted { lhs, rhs in
            let priorityLhs = lhs.phase.sortPriority
            let priorityRhs = rhs.phase.sortPriority
            if priorityLhs != priorityRhs {
                return priorityLhs < priorityRhs
            }
            let lhsApproval = lhs.phase.isWaitingForApproval
            let rhsApproval = rhs.phase.isWaitingForApproval
            // Approval items always come before non-approval peers in the same bucket.
            if lhsApproval != rhsApproval {
                return lhsApproval
            }
            // For non-approval peers, keep the existing unread-first behavior.
            if !lhsApproval, lhs.hasUnreadUpdate != rhs.hasUnreadUpdate {
                return lhs.hasUnreadUpdate
            }
            let dateLhs = lhs.lastUserMessageDate ?? lhs.lastActivity
            let dateRhs = rhs.lastUserMessageDate ?? rhs.lastActivity
            return dateLhs > dateRhs
        }
    }
}

// MARK: - SessionPhaseHelpers

enum SessionPhaseHelpers {
    /// Get color for session phase
    static func phaseColor(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval:
            TerminalColors.amber
        case .waitingForInput:
            TerminalColors.green
        case .processing:
            TerminalColors.cyan
        case .compacting:
            TerminalColors.magenta
        case .idle,
             .ended:
            TerminalColors.dim
        }
    }

    /// Get description for session phase
    static func phaseDescription(for phase: SessionPhase) -> String {
        switch phase {
        case let .waitingForApproval(ctx):
            "Waiting for approval: \(ctx.toolName)"
        case .waitingForInput:
            "Ready for input"
        case .processing:
            "Processing..."
        case .compacting:
            "Compacting context..."
        case .idle:
            "Idle"
        case .ended:
            "Ended"
        }
    }

    /// Format time ago string
    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
