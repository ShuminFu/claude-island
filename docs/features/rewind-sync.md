# Feature: /rewind Conversation Sync

## Problem

When a user runs `/rewind` in Claude Code CLI to roll back to a previous conversation checkpoint, Claude Island's chat view continues displaying the old (pre-rewind) messages. The UI does not reflect that the conversation has been rewound until the user sends a new message.

### Root Cause Chain

1. `/rewind` **truncates** the JSONL conversation file — removes all messages after the selected checkpoint
2. `/rewind` does **not** fire any hook event (it is not among Claude Code's 26 hook event types)
3. `ConversationParser.parseIncremental()` only runs when `scheduleFileSync()` is called, which is triggered by hook events (`UserPromptSubmit`, `PostToolUse`, `Stop`)
4. Even when truncation is eventually detected (`fileSize < lastOffset`), the parser resets its state to empty and positions at the file end — it does **not** re-parse the remaining content
5. `SessionStore.chatItems` retains stale messages because no `clearDetected` flag is set

### Evidence

JSONL first-line comparison across sessions:

| Session | First line type | Status |
|---------|----------------|--------|
| Normal session | `permission-mode` | Fresh start |
| Rewound session | `file-history-snapshot` | Truncated — `permission-mode` and prior messages removed |

## Goal

When `/rewind` truncates the JSONL file, Island should:

1. Detect the truncation in real-time (without waiting for a hook event)
2. Re-parse the truncated file from the beginning to rebuild chat history
3. Replace stale `chatItems` in `SessionStore` with the correct post-rewind messages
4. UI reflects the rewound conversation state within ~100ms

## Current Behavior

```
User runs /rewind in CLI
  → JSONL file truncated (e.g., 500KB → 200KB)
  → No hook event fires
  → JSONLInterruptWatcher sees file change but IGNORES shrinkage:
       guard currentSize > self.lastOffset else { return }  // line 192
  → ConversationParser is never called
  → SessionStore.chatItems unchanged
  → UI shows stale pre-rewind messages
  → ... user sends next message ...
  → UserPromptSubmit hook fires → scheduleFileSync()
  → ConversationParser detects truncation (fileSize < lastOffset)
  → State reset to empty, offset jumps to file end
  → Post-rewind messages are SKIPPED (not re-parsed)
  → Only new messages after the rewind appear
```

## Watcher Lifecycle Problem

Before designing the solution, there is a critical lifecycle constraint:

`JSONLInterruptWatcher` is **not always running**. Its lifecycle is tied to the session's `processing` phase:

```
Session enters processing (hook event with sessionPhase == .processing)
  → InterruptWatcherManager.startWatching()        ← watcher starts

Session stops (Stop hook event / interrupt detected / session ended)
  → InterruptWatcherManager.stopWatching()          ← watcher stops
```

When the user runs `/rewind`, the session is in `waitingForInput` state — the watcher has already been stopped by the previous `Stop` event. **Extending the interrupt watcher alone is insufficient.**

### Watcher Lifecycle (ClaudeSessionMonitor.swift)

| Event | Action |
|-------|--------|
| Hook event with `sessionPhase == .processing` (line 156) | `startWatching()` |
| Hook event with `status == "ended"` (line 164) | `stopWatching()` |
| Interrupt detected (line 33) | `stopWatching()` |

## Solution Design

### Approach: New Dedicated File Size Watcher (Always-On)

Create a separate, always-on file size watcher that runs for the entire lifetime of a tracked session (from first hook event to session end). This watcher's sole purpose is detecting file truncation — it does not parse content.

**Why not extend JSONLInterruptWatcher?** Its start/stop lifecycle is bound to the `processing` phase. `/rewind` happens during `waitingForInput` when the watcher is stopped. Changing InterruptWatcher's lifecycle would affect interrupt detection semantics.

**Why not use the periodic check (3s)?** It only calls `scheduleFileSync()` for sessions in `processing` or `waitingForApproval` phase — idle sessions are skipped. And 3 seconds is noticeable latency.

### Data Flow (After Fix)

```
Session first appears (any hook event)
  → RewindWatcher starts monitoring JSONL file size via DispatchSource
  → Runs continuously regardless of session phase

User runs /rewind in CLI (session is idle/waitingForInput)
  → JSONL file truncated
  → DispatchSource fires event
  → RewindWatcher detects: currentSize < lastKnownSize → TRUNCATION
  → Fires rewindDetected event to SessionStore
  → ConversationParser.resetState() + parseFullConversation()
  → SessionStore replaces chatItems with re-parsed messages
  → publishState() → AsyncStream → UI updates

Session ends (status == "ended")
  → RewindWatcher stopped and removed
```

### Implementation Details

#### 1. New RewindWatcher (Lightweight File Size Monitor)

A minimal actor that only tracks file size changes via DispatchSource. Much simpler than JSONLInterruptWatcher — no content parsing, no offset tracking for reads.

```swift
actor RewindWatcher {
    private let sessionID: String
    private let filePath: String
    private var lastKnownSize: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private let onTruncation: @Sendable (String) -> Void

    func start() {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return }
        self.lastKnownSize = (try? handle.seekToEnd()) ?? 0

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.checkForTruncation() }
        }
        source.resume()
        self.source = source
    }

    private func checkForTruncation() {
        // Stat the file to get current size (FileHandle may be stale after truncate)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let currentSize = attrs[.size] as? UInt64 else { return }

        if currentSize < self.lastKnownSize {
            // File shrunk → rewind detected
            let sid = self.sessionID
            let callback = self.onTruncation
            Task(name: "rewind-notify") { @MainActor in callback(sid) }
        }
        self.lastKnownSize = currentSize
    }
}
```

Key differences from JSONLInterruptWatcher:
- **Always-on**: Lives from session registration to session end
- **No content reading**: Only checks file size via `attributesOfItem` (cheap stat call)
- **Event mask includes `.delete`/`.attrib`**: Truncation may trigger different FS events
- **Uses `.utility` QoS**: Not latency-critical like interrupt detection

#### 2. Lifecycle: Bind to SessionStore.sessions Dictionary

No separate manager needed. `SessionStore` already tracks all live sessions in its `sessions: [String: SessionState]` dictionary with well-defined create/remove points:

| Event | SessionStore action | RewindWatcher action |
|-------|-------------------|---------------------|
| First hook event for new sessionID (line 308) | `sessions[id] = createSession()` | `rewindWatchers[id] = RewindWatcher(); start()` |
| Hook event `status == "ended"` (line 320) | `sessions.removeValue(forKey: id)` | `rewindWatchers[id]?.stop(); remove` |
| Periodic check: process dead (PeriodicCheck line 43) | `process(.sessionEnded(id))` → `removeValue` | Same cleanup via `.sessionEnded` handler |

Watcher count = active session count (typically 1-5). Sessions never accumulate because:
- `status == "ended"` removes immediately
- 3-second periodic check detects dead processes via `kill(pid, 0)`

Add a `rewindWatchers: [String: RewindWatcher]` dictionary to `SessionStore` alongside the existing `sessions` dictionary. Wire up create/cleanup in `processHookEvent()` and the `.sessionEnded` handler.

#### 3. ConversationParser — Full Re-parse on Truncation

Add a dedicated method for rewind re-parse:

```swift
func reparseAfterTruncation(sessionID: String, cwd: String) async -> [ChatMessage] {
    // Reset incremental state completely
    self.incrementalState.removeValue(forKey: sessionID)
    // Re-parse the full file from offset 0
    return await self.parseFullConversation(sessionID: sessionID, cwd: cwd)
}
```

This differs from the current truncation handling (which resets state but positions at file end, skipping content).

#### 3. SessionEvent — Add Rewind Event

```swift
case rewindDetected(sessionID: String, cwd: String)
```

#### 4. SessionStore — Handle Rewind Event

In `process(_ event:)`:

```swift
case .rewindDetected(let sessionID, let cwd):
    await processRewind(sessionID: sessionID, cwd: cwd)
```

`processRewind` method:

```swift
private func processRewind(sessionID: String, cwd: String) async {
    // Full re-parse from beginning
    let allMessages = await ConversationParser.shared.reparseAfterTruncation(
        sessionID: sessionID, cwd: cwd
    )
    let conversationInfo = await ConversationParser.shared.parse(
        sessionID: sessionID, cwd: cwd
    )

    guard var session = sessions[sessionID] else { return }

    // Replace all chat state
    session.chatItems = []
    session.toolTracker = ToolTracker()
    session.subagentState = SubagentState()
    session.conversationInfo = conversationInfo

    // Rebuild chatItems from re-parsed messages
    let payload = FileUpdatePayload(
        sessionID: sessionID, cwd: cwd,
        messages: allMessages,
        isIncremental: false,     // full replacement
        clearDetected: false,
        completedToolIDs: /* from parser */,
        toolResults: /* from parser */,
        structuredResults: /* from parser */,
    )
    self.processMessages(from: payload, into: &session)
    session.chatItems.sort { $0.timestamp < $1.timestamp }

    self.sessions[sessionID] = session
    self.publishState()
}
```

#### 5. InterruptWatcherManager — Wire Up Truncation Callback

```swift
func startWatching(sessionID: String, cwd: String) {
    let watcher = JSONLInterruptWatcher(
        sessionID: sessionID, cwd: cwd,
        onInterrupt: interruptCallback,
        onTruncation: { sessionID in
            Task {
                await SessionStore.shared.process(
                    .rewindDetected(sessionID: sessionID, cwd: cwd)
                )
            }
        }
    )
}
```

## Key Files to Modify

| File | Change |
|------|--------|
| **New**: `ClaudeIsland/Services/Session/RewindWatcher.swift` | New file: `RewindWatcher` actor (lightweight file size monitor) |
| `ClaudeIsland/Services/State/SessionStore.swift` | Add `rewindWatchers` dict, create in `processHookEvent()`, cleanup in `.sessionEnded` |
| `ClaudeIsland/Services/Session/ConversationParser.swift` | Add `reparseAfterTruncation()` method |
| `ClaudeIsland/Models/SessionEvent.swift` | Add `.rewindDetected` event case |
| `ClaudeIsland/Services/State/SessionStore.swift` | Add `processRewind()` handler |

## Key Files (Read-Only Reference)

| File | Why |
|------|-----|
| `ClaudeIsland/Services/Session/JSONLInterruptWatcher.swift` | Reference for DispatchSource pattern, do NOT modify (different lifecycle) |
| `ClaudeIsland/Services/State/SessionStore+PeriodicCheck.swift` | Fallback periodic check (3s) — can extend as secondary detection |
| `ClaudeIsland/Services/Chat/ChatHistoryManager.swift` | Subscribes to `SessionStore.sessionsStream()` — no changes needed, will auto-update |
| `ClaudeIsland/UI/Views/ChatView.swift` | Observes `ChatHistoryManager.histories` — no changes needed |
| `ClaudeIsland/Models/SessionState.swift` | `chatItems`, `toolTracker`, `subagentState` fields that get reset |

## Edge Cases

- **File deleted entirely** (session end, not rewind): `fileExists` check returns false → no action (existing behavior)
- **Rapid consecutive rewinds**: Debounce truncation callback (100ms, matching existing `syncDebounce`) to coalesce multiple DispatchSource events
- **Rewind to beginning** (file becomes very small, only `file-history-snapshot` remains): Re-parse produces 0 chat messages → `chatItems` cleared, UI shows empty state
- **Rewind while file sync in progress**: Cancel pending sync via `cancelPendingSync()` before re-parse to avoid race
- **File size decrease from compaction** (not rewind): `PreCompact` hook fires before compaction → if we see truncation AND a recent `PreCompact` event, it's compaction not rewind. However, treating compaction as rewind is safe (re-parse still produces correct state)
- **DispatchSource not firing on truncate**: Some macOS filesystem edge cases. Periodic check (3s) serves as fallback — extend it to compare file sizes
- **FileHandle stale after truncate**: DispatchSource holds an fd, but truncation may invalidate it on some FS. Use `FileManager.attributesOfItem` (stat) instead of seeking the handle to get current size
- **Watcher resource cost**: One DispatchSource per active session. Lightweight (no content reading, only stat on event). Acceptable for typical 1-5 concurrent sessions

## Out of Scope (Future)

- Visual indicator in UI showing "conversation was rewound"
- Animating the chat history transition (smooth removal of stale messages)
- Supporting `/fork` (creates a new session, different mechanism)
- Requesting Anthropic to add a `/rewind` hook event to Claude Code
