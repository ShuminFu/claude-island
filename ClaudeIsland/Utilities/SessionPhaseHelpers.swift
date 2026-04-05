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
    func sortedByPriority() -> [SessionState] {
        self.sorted { lhs, rhs in
            let priorityLhs = lhs.phase.sortPriority
            let priorityRhs = rhs.phase.sortPriority
            if priorityLhs != priorityRhs {
                return priorityLhs < priorityRhs
            }
            // Within same priority: unread before read
            if lhs.hasUnreadUpdate != rhs.hasUnreadUpdate {
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
