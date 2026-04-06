# Feature: Smart Summary

## Problem

When a Claude Code session enters `waitingForInput` (task complete / ready), the session list shows a generic "Ready" or "Task complete" status text. Users cannot tell at a glance what each session was working on without clicking into it.

## Goal

Synthesize a one-line smart summary from session conversation data, displayed as the subtitle when no real-time activity is available. No AI/LLM calls — pure data extraction with multi-level fallback.

## Design

### `smartSummary` Computed Property (SessionState)

Multi-level fallback chain:

```
Level 1: conversationInfo.summary (explicit JSONL summary)
  ↓ nil
Level 2: Synthesize from conversation data
  prefix = lastUserMessage(30) > firstUserMessage(30) > projectName
  + lastToolName → "[prefix] → [tool]: [lastMessage(40)]"
  + lastMessage  → "[prefix]: [lastMessage(40)]"
  + otherwise    → prefix
  ↓ no data
Level 3: directParseFirstMessage() — emergency JSONL read
  reverse scan last 500 lines → "[user(30)]\n[assistant(50)]"
  ↓ file not found
Level 4: nil (falls through to phaseStatusText)
```

### Example Outputs

| Data Available | Output |
|---------------|--------|
| summary = "Fix auth bug" | `Fix auth bug` |
| lastUserMessage + lastToolName=Read + lastMessage=main.swift | `Fix authentication... → Read: main.swift` |
| lastUserMessage + lastMessage (no tool) | `Fix authentication...: Error occurred during...` |
| only firstUserMessage | `Help me debug this issue` |
| JSONL fallback (user+assistant) | `Fix auth\nI've fixed the authentication...` (two-line) |

### Truncation Rules

| Field | Max Length |
|-------|-----------|
| prefix (lastUserMessage / firstUserMessage) | 30 chars |
| lastMessage in synthesized summary | 40 chars |
| directParse: user part | 30 chars |
| directParse: assistant part | 50 chars |

### UI Display (ClaudeInstancesView)

When `lastMessage` and `lastMessageRole` are both nil (no active tool/message), smartSummary renders:

- **Two-line** (contains `\n`): "You: [question]" + "AI [answer]" — from directParseFirstMessage fallback
- **Single-line**: "AI [summary]" — from synthesized or explicit summary

Font size: 10pt (slightly smaller than active status at 11pt) to visually distinguish idle summary from live activity.

### `displayTitle` Enhancement

Added `lastUserMessage` as a fallback layer:

```
summary > lastUserMessage > firstUserMessage > projectName
```

This gives sessions better titles when no explicit summary exists in the JSONL.

## Files Changed

| File | Change |
|------|--------|
| `ClaudeIsland/Models/SessionState.swift` | Added `smartSummary`, `directParseFirstMessage`, `parseFirstUserMessage`, `extractText`; enhanced `displayTitle` |
| `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` | Added smartSummary display branch in InstanceRow subtitle area |

## System Message Filtering

The `extractText` helper filters out system messages with these prefixes:
- `<command-name>` — slash commands
- `<local-command` — local command output
- `<system-reminder>` — system context
- `<task-notification>` — background task updates
- `Caveat:` — system caveats
- `[Request interrupted` — interrupt markers
