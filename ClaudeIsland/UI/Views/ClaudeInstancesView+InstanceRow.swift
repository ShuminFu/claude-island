//
//  ClaudeInstancesView+InstanceRow.swift
//  ClaudeIsland
//
//  Extracted InstanceRow — one row in the session list.
//

import AppKit
import SwiftUI

// MARK: - InstanceRow

struct InstanceRow: View { // swiftlint:disable:this type_body_length
    // MARK: Internal

    let session: SessionState
    var isSelected = false
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    var onHoverStart: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            self.mainRow

            if self.isEditing {
                SessionLabelEditor(sessionID: self.session.sessionID)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.isEditing)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(self.isSelected ? Color.white.opacity(0.10) : (self.isHovered ? Color.white.opacity(0.06) : Color.clear)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(self.isSelected ? Color.white.opacity(0.15) : Color.clear, lineWidth: 1),
        )
        .onAlwaysActiveHover { hovering in
            self.isHovered = hovering
            if hovering {
                self.onHoverStart?()
                // Mark as read when mouse hovers over the row
                if self.session.hasUnreadUpdate {
                    Task(name: "hover-mark-read") {
                        await SessionStore.shared.process(.markAsRead(sessionID: self.session.sessionID))
                    }
                }
            }
        }
        .onChange(of: self.isSelected) { _, selected in
            // Mark as read when keyboard navigation selects this row
            if selected, self.session.hasUnreadUpdate {
                Task(name: "select-mark-read") {
                    await SessionStore.shared.process(.markAsRead(sessionID: self.session.sessionID))
                }
            }
        }
        .onRightClick {
            withAnimation {
                if !self.isEditing {
                    self.editingName = self.displayTitle
                }
                self.isEditing.toggle()
            }
        }
        .onChange(of: self.isEditing) { _, newValue in
            if !newValue {
                self.saveName()
            }
        }
    }

    // MARK: Private

    private enum HoverZone {
        case title, userMsg, agentMsg
    }

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editingName = ""
    @State private var hoverZone: HoverZone?
    @State private var pendingHoverExit: Task<Void, Never>?
    @FocusState private var isTitleFocused: Bool

    private let metadataManager = SessionMetadataManager.shared
    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    private var isTitleHovered: Bool { self.hoverZone == .title }
    private var isUserMsgHovered: Bool { self.hoverZone == .userMsg }
    private var isAgentMsgHovered: Bool { self.hoverZone == .agentMsg }

    private var activityTextSize: CGFloat { self.isAgentMsgHovered ? 13 : 11 }
    private var activityPrimaryOpacity: Double { self.isAgentMsgHovered ? 0.85 : 0.4 }
    private var activityLabelOpacity: Double { self.isAgentMsgHovered ? 1.0 : 0.5 }
    private var activityCyanPrimaryOpacity: Double { self.isAgentMsgHovered ? 0.9 : 0.5 }
    private var activityCyanLabelOpacity: Double { self.isAgentMsgHovered ? 1.0 : 0.7 }

    private var displayTitle: String {
        self.metadataManager.name(for: self.session.sessionID) ?? self.session.displayTitle
    }

    private var isWaitingForApproval: Bool {
        self.session.phase.isWaitingForApproval
    }

    private var isInteractiveTool: Bool {
        guard let toolName = self.session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    private var phaseStatusText: String {
        switch self.session.phase {
        case .processing: "Processing..."
        case .compacting: "Compacting..."
        case .waitingForInput: self.session.hasUnreadUpdate ? "Task complete" : "Ready"
        case .waitingForApproval: "Waiting for approval"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }

    private var mainRow: some View {
        HStack(spacing: 0) {
            if let color = self.metadataManager.color(for: self.session.sessionID) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }

            HStack(alignment: .center, spacing: 10) {
                self.stateIndicator
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if self.isEditing {
                            TextField("Session name", text: self.$editingName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .focused(self.$isTitleFocused)
                                .onSubmit {
                                    withAnimation { self.isEditing = false }
                                }
                                .onAppear { self.isTitleFocused = true }
                        } else {
                            Text(self.displayTitle)
                                .font(.system(size: 13, weight: self.session.hasUnreadUpdate ? .semibold : .medium))
                                .foregroundColor(self.session.hasUnreadUpdate ? .white : .white.opacity(0.85))
                                .lineLimit(1)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .onAlwaysActiveHover { hovering in
                                    if hovering {
                                        self.enterHoverZone(.title)
                                    } else {
                                        self.scheduleHoverExit(.title)
                                    }
                                }
                        }

                        if let repoName = self.session.gitRepoName {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8))
                                if !self.isTitleHovered {
                                    if let branch = self.session.gitBranch {
                                        Text("\(repoName) / \(branch)")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                    } else {
                                        Text(repoName)
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                    }
                                    if self.session.gitIsWorktree {
                                        Image(systemName: "square.on.square")
                                            .font(.system(size: 7))
                                    }
                                }
                            }
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                        }

                        if let usage = self.session.usage {
                            Text(usage.formattedTotal)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }

                    // Show last user message above current activity
                    if let lastUserMsg = self.session.lastUserMessage,
                       self.session.lastMessageRole != "user" {
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: self.isUserMsgHovered ? 13 : 10, weight: .medium))
                                .foregroundColor(.white.opacity(self.isUserMsgHovered ? 0.85 : 0.35))
                            Text(lastUserMsg)
                                .font(.system(size: self.isUserMsgHovered ? 13 : 10))
                                .foregroundColor(.white.opacity(self.isUserMsgHovered ? 0.85 : 0.3))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 18)
                        .contentShape(Rectangle())
                        .onAlwaysActiveHover { hovering in
                            if hovering {
                                self.enterHoverZone(.userMsg)
                            } else {
                                self.scheduleHoverExit(.userMsg)
                            }
                        }
                    }

                    Group {
                        if self.isWaitingForApproval, let toolName = self.session.pendingToolName {
                            HStack(spacing: 4) {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: self.activityTextSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(TerminalColors.amber.opacity(self.isAgentMsgHovered ? 1.0 : 0.9))
                                if self.isInteractiveTool {
                                    Text("Needs your input")
                                        .font(.system(size: self.activityTextSize))
                                        .foregroundColor(.white.opacity(self.activityLabelOpacity))
                                        .lineLimit(1)
                                } else if let input = self.session.pendingToolInput {
                                    Text(input)
                                        .font(.system(size: self.activityTextSize))
                                        .foregroundColor(.white.opacity(self.activityLabelOpacity))
                                        .lineLimit(1)
                                }
                            }
                        } else if let role = self.session.lastMessageRole {
                            switch role {
                            case "tool":
                                HStack(spacing: 4) {
                                    if let toolName = self.session.lastToolName {
                                        Text(MCPToolFormatter.formatToolName(toolName))
                                            .font(.system(size: self.activityTextSize, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(self.activityLabelOpacity))
                                    }
                                    if let input = self.session.lastMessage {
                                        Text(input)
                                            .font(.system(size: self.activityTextSize))
                                            .foregroundColor(.white.opacity(self.activityPrimaryOpacity))
                                            .lineLimit(1)
                                    }
                                }
                            case "user":
                                HStack(spacing: 4) {
                                    Text("You:")
                                        .font(.system(size: self.activityTextSize, weight: .medium))
                                        .foregroundColor(.white.opacity(self.activityLabelOpacity))
                                    if let msg = self.session.lastMessage {
                                        Text(msg)
                                            .font(.system(size: self.activityTextSize))
                                            .foregroundColor(.white.opacity(self.activityPrimaryOpacity))
                                            .lineLimit(1)
                                    }
                                }
                            default:
                                if let msg = self.session.lastMessage {
                                    Text(msg)
                                        .font(.system(size: self.activityTextSize))
                                        .foregroundColor(.white.opacity(self.activityPrimaryOpacity))
                                        .lineLimit(1)
                                }
                            }
                        } else if let lastMsg = self.session.lastMessage {
                            Text(lastMsg)
                                .font(.system(size: self.activityTextSize))
                                .foregroundColor(.white.opacity(self.activityPrimaryOpacity))
                                .lineLimit(1)
                        } else if let summary = self.session.smartSummary {
                            let parts = summary.components(separatedBy: "\n")
                            if parts.count >= 2 {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("You:")
                                            .font(.system(size: self.activityTextSize, weight: .medium))
                                            .foregroundColor(.white.opacity(self.activityLabelOpacity))
                                        Text(parts[0])
                                            .font(.system(size: self.activityTextSize))
                                            .foregroundColor(.white.opacity(self.isAgentMsgHovered ? 0.9 : 0.7))
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 4) {
                                        Text("AI:")
                                            .font(.system(size: self.activityTextSize, weight: .medium))
                                            .foregroundColor(.cyan.opacity(self.activityCyanLabelOpacity))
                                        Text(parts[1])
                                            .font(.system(size: self.activityTextSize))
                                            .foregroundColor(.cyan.opacity(self.activityCyanPrimaryOpacity))
                                            .lineLimit(1)
                                    }
                                }
                            } else {
                                HStack(spacing: 4) {
                                    Text("AI:")
                                        .font(.system(size: self.activityTextSize, weight: .medium))
                                        .foregroundColor(.cyan.opacity(self.activityCyanLabelOpacity))
                                    Text(summary)
                                        .font(.system(size: self.activityTextSize))
                                        .foregroundColor(.cyan.opacity(self.activityCyanPrimaryOpacity))
                                        .lineLimit(1)
                                }
                            }
                        } else {
                            Text(self.phaseStatusText)
                                .font(.system(size: self.activityTextSize))
                                .foregroundColor(.white.opacity(self.activityPrimaryOpacity))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                    .contentShape(Rectangle())
                    .onAlwaysActiveHover { hovering in
                        if hovering {
                            self.enterHoverZone(.agentMsg)
                        } else {
                            self.scheduleHoverExit(.agentMsg)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: self.hoverZone)

                Spacer(minLength: 0)

                if self.isWaitingForApproval && self.isInteractiveTool {
                    if self.session.pid != nil {
                        TerminalButton(isEnabled: true) { self.onFocus() }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                } else if self.isWaitingForApproval {
                    InlineApprovalButtons(
                        onApprove: self.onApprove,
                        onReject: self.onReject,
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    HStack(spacing: 8) {
                        if self.session.pid != nil {
                            IconButton(icon: "terminal") { self.onFocus() }
                        }
                        if self.session.phase == .idle || self.session.phase == .waitingForInput {
                            IconButton(icon: "archivebox") { self.onArchive() }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.leading, self.metadataManager.color(for: self.session.sessionID) != nil ? 4 : 8)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !self.isEditing { self.onChat() }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.isWaitingForApproval)
    }

    @ViewBuilder private var stateIndicator: some View {
        switch self.session.phase {
        case .processing,
             .compacting:
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % self.spinnerSymbols.count
                Text(self.spinnerSymbols[phase])
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(self.claudeOrange)
            }
        case .waitingForApproval:
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % self.spinnerSymbols.count
                Text(self.spinnerSymbols[phase])
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(TerminalColors.amber)
            }
        case .waitingForInput:
            if self.session.hasUnreadUpdate {
                UnreadDot(color: TerminalColors.green)
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
            }
        case .idle,
             .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

    private func saveName() {
        let trimmed = self.editingName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == self.session.displayTitle {
            self.metadataManager.setName(nil, for: self.session.sessionID)
        } else {
            self.metadataManager.setName(trimmed, for: self.session.sessionID)
        }
    }

    /// Enter a hover zone immediately; cancels any pending exit so a re-entry
    /// that happens during a flicker blip does not clear the state mid-animation.
    private func enterHoverZone(_ zone: HoverZone) {
        self.pendingHoverExit?.cancel()
        self.pendingHoverExit = nil
        if self.hoverZone != zone {
            self.hoverZone = zone
        }
    }

    /// Debounce hover exits so a momentary mouse-out (caused by layout reflow
    /// when text grows/shrinks) does not flicker the state.
    private func scheduleHoverExit(_ zone: HoverZone) {
        guard self.hoverZone == zone else { return }
        self.pendingHoverExit?.cancel()
        self.pendingHoverExit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if self.hoverZone == zone {
                self.hoverZone = nil
            }
        }
    }
}
