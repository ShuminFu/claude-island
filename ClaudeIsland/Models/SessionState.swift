//
//  SessionState.swift
//  ClaudeIsland
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

// MARK: - SessionState

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
nonisolated struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: Lifecycle

    // MARK: - Initialization

    nonisolated init(
        sessionID: String,
        cwd: String,
        projectName: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        terminalTTY: String? = nil,
        isInTmux: Bool = false,
        gitRepoName: String? = nil,
        gitBranch: String? = nil,
        gitIsWorktree: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            firstUserMessage: nil,
            lastUserMessage: nil,
            lastUserMessageDate: nil,
            usage: nil,
        ),
        hasUnreadUpdate: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date(),
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.pid = pid
        self.tty = tty
        self.terminalTTY = terminalTTY
        self.isInTmux = isInTmux
        self.gitRepoName = gitRepoName
        self.gitBranch = gitBranch
        self.gitIsWorktree = gitIsWorktree
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.hasUnreadUpdate = hasUnreadUpdate
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: Internal

    // MARK: - Identity

    let sessionID: String
    let cwd: String
    let projectName: String

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    /// Terminal's real TTY path (client TTY in tmux, same as `tty` otherwise).
    /// Used for tab title control via OSC escape sequences.
    var terminalTTY: String?
    var isInTmux: Bool

    // MARK: - Git Info

    /// Git repository name (derived from repo root path). Nil if not in a git repo.
    var gitRepoName: String?
    /// Current git branch name. Nil if detached HEAD or not a git repo.
    var gitBranch: String?
    /// Whether this session is in a git worktree (not the main working tree).
    var gitIsWorktree: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Unread Status

    /// Whether this session has an unread status change (agent finished, permission request arrived)
    var hasUnreadUpdate: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String {
        self.sessionID
    }

    // MARK: - Derived Properties

    /// Display-friendly project label: prefers git repo name, falls back to folder name
    var projectLabel: String {
        self.gitRepoName ?? self.projectName
    }

    /// Whether this session needs user attention
    var needsAttention: Bool {
        self.phase.needsAttention
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case let .waitingForApproval(ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionID for animation stability)
    var stableID: String {
        if let pid {
            return "\(pid)-\(self.sessionID)"
        }
        return self.sessionID
    }

    /// Display title: summary > first user message > project name
    var displayTitle: String {
        self.conversationInfo.summary ?? self.conversationInfo.firstUserMessage ?? self.projectName
    }

    /// Smart one-line summary synthesized from session data.
    /// Priority: explicit summary → "[userMsg] → [tool]: [lastMsg]" → direct JSONL parse → nil
    var smartSummary: String? {
        if let summary = self.conversationInfo.summary {
            return summary
        }

        let prefix: String
        if let latest = self.conversationInfo.lastUserMessage {
            prefix = latest.count > 30 ? String(latest.prefix(30)) + "..." : latest
        } else if let first = self.conversationInfo.firstUserMessage {
            prefix = first.count > 30 ? String(first.prefix(30)) + "..." : first
        } else {
            prefix = self.projectName
        }

        if let toolName = self.conversationInfo.lastToolName {
            let lastPart: String
            if let last = self.conversationInfo.lastMessage {
                lastPart = last.count > 40 ? String(last.prefix(40)) + "..." : last
            } else {
                lastPart = ""
            }
            if lastPart.isEmpty {
                return "\(prefix) → \(toolName)"
            }
            return "\(prefix) → \(toolName): \(lastPart)"
        }

        // No tool name — just return prefix if we have any useful info
        if self.conversationInfo.firstUserMessage != nil || self.conversationInfo.lastMessage != nil {
            if let last = self.conversationInfo.lastMessage {
                let lastPart = last.count > 40 ? String(last.prefix(40)) + "..." : last
                return "\(prefix): \(lastPart)"
            }
            return prefix
        }

        // Fallback: directly read JSONL to extract first user message
        if let msg = Self.directParseFirstMessage(sessionID: self.sessionID, cwd: self.cwd) {
            return msg
        }
        return nil
    }

    /// Best hint for matching window title
    var windowHint: String {
        self.conversationInfo.summary ?? self.projectName
    }

    /// Pending tool name if waiting for approval
    var pendingToolName: String? {
        self.activePermission?.toolName
    }

    /// Pending tool use ID
    var pendingToolID: String? {
        self.activePermission?.toolUseID
    }

    /// Formatted pending tool input for display
    var pendingToolInput: String? {
        self.activePermission?.formattedInput
    }

    /// Last message content
    var lastMessage: String? {
        self.conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        self.conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        self.conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        self.conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        self.conversationInfo.firstUserMessage
    }

    /// Most recent user message (for session list subtitle)
    var lastUserMessage: String? {
        self.conversationInfo.lastUserMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        self.conversationInfo.lastUserMessageDate
    }

    /// Token usage for this session
    var usage: UsageInfo? {
        self.conversationInfo.usage
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        self.phase.needsAttention
    }

    // MARK: - Smart Summary Helpers

    /// Emergency fallback: read JSONL directly without going through ConversationParser
    private static func directParseFirstMessage(sessionID: String, cwd: String) -> String? {
        var searchCwd = cwd
        let projectsDir = NSHomeDirectory() + "/.claude/projects"

        while !searchCwd.isEmpty, searchCwd != "/" {
            let projectDir = searchCwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
            let path = projectsDir + "/" + projectDir + "/" + sessionID + ".jsonl"
            if FileManager.default.fileExists(atPath: path) {
                return parseFirstUserMessage(from: path)
            }
            searchCwd = (searchCwd as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func parseFirstUserMessage(from path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var lastUserMsg: String?
        var lastAssistantMsg: String?

        for line in lines.reversed().prefix(500) {
            guard let ld = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let type = json["type"] as? String,
                  !(json["isMeta"] as? Bool ?? false),
                  let msg = json["message"] as? [String: Any]
            else { continue }

            guard let text = extractText(from: msg) else { continue }

            if type == "assistant", lastAssistantMsg == nil {
                lastAssistantMsg = String(text.prefix(80))
            }
            if type == "user", lastUserMsg == nil {
                lastUserMsg = String(text.prefix(40))
            }
            if lastUserMsg != nil, lastAssistantMsg != nil { break }
        }

        if let user = lastUserMsg, let assistant = lastAssistantMsg {
            let userPart = user.count > 30 ? String(user.prefix(30)) + "..." : user
            let assistPart = assistant.count > 50 ? String(assistant.prefix(50)) + "..." : assistant
            return "\(userPart)\n\(assistPart)"
        }
        if let assistant = lastAssistantMsg {
            return assistant
        }
        return lastUserMsg
    }

    /// Extract text content from a message (handles both String and Array formats)
    private static func extractText(from msg: [String: Any]) -> String? {
        if let content = msg["content"] as? String,
           !Self.isSystemPrefix(content) {
            return content
        }
        if let arr = msg["content"] as? [[String: Any]] {
            for block in arr where block["type"] as? String == "text" {
                if let text = block["text"] as? String,
                   !Self.isSystemPrefix(text),
                   !text.hasPrefix("[Request interrupted") {
                    return text
                }
            }
        }
        return nil
    }

    private static func isSystemPrefix(_ text: String) -> Bool {
        text.hasPrefix("<command-name>") ||
            text.hasPrefix("<local-command") ||
            text.hasPrefix("<system-reminder>") ||
            text.hasPrefix("<task-notification>") ||
            text.hasPrefix("Caveat:")
    }
}

// MARK: - ToolTracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
nonisolated struct ToolTracker: Equatable, Sendable {
    // MARK: Lifecycle

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIDs: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil,
    ) {
        self.inProgress = inProgress
        self.seenIDs = seenIDs
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    // MARK: Internal

    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIDs: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        self.seenIDs.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        self.seenIDs.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard self.markSeen(id) else { return }
        self.inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running,
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        self.inProgress.removeValue(forKey: id)
    }
}

// MARK: - ToolInProgress

/// A tool currently in progress
nonisolated struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

// MARK: - ToolInProgressPhase

/// Phase of a tool in progress
nonisolated enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - SubagentState

/// State for Task (subagent) tools
nonisolated struct SubagentState: Equatable, Sendable {
    // MARK: Lifecycle

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    // MARK: Internal

    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentID to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !self.activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolID: String, description: String? = nil) {
        self.activeTasks[taskToolID] = TaskContext(
            taskToolID: taskToolID,
            startTime: Date(),
            agentID: nil,
            description: description,
            subagentTools: [],
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolID: String) {
        self.activeTasks.removeValue(forKey: taskToolID)
    }

    /// Set the agentID for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentID(_ agentID: String, for taskToolID: String) {
        self.activeTasks[taskToolID]?.agentID = agentID
        if let description = activeTasks[taskToolID]?.description {
            self.agentDescriptions[agentID] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskID: String) {
        self.activeTasks[taskID]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskID: String) {
        self.activeTasks[taskID]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskID = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        })
        else { return }

        self.activeTasks[mostRecentTaskID]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolID: String, status: ToolStatus) {
        for taskID in self.activeTasks.keys {
            if let index = activeTasks[taskID]?.subagentTools.firstIndex(where: { $0.id == toolID }) {
                self.activeTasks[taskID]?.subagentTools[index].status = status
                return
            }
        }
    }
}

// MARK: - TaskContext

/// Context for an active Task tool
nonisolated struct TaskContext: Equatable, Sendable {
    let taskToolID: String
    let startTime: Date
    var agentID: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
