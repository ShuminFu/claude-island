---
name: view-logs
description: Inspect Claude Island runtime logs via macOS unified logging (log show / log stream). Use when diagnosing runtime behavior, verifying a fix in a running build, or tracing session/parser/hook events. Covers subsystem filters, the info/debug level trap, category list, and key phrases that point at common bugs.
---

# Viewing Claude Island Logs

Claude Island logs via `os.Logger` to the macOS unified logging system. There are **no log files on disk** — everything flows through `log show` / `log stream`.

## Subsystem & process

- **Subsystem**: `com.engels74.ClaudeIsland`
- **Process name**: `Claude Island` (with a space — quote it)
- **PID lookup**: `ps aux | grep -i "claude island" | grep -v grep`

Either filter works; `process == "Claude Island"` is more permissive (catches subsystems you didn't know about), `subsystem == "com.engels74.ClaudeIsland"` is tighter.

## The info/debug level trap

**Default `log show` hides `info` and `debug` messages.** You will see nothing useful unless you pass `--info --debug`. Most Claude Island runtime traces are at `info` or `debug` level — this is the #1 reason "logs look empty."

```bash
# WRONG — hides most Claude Island output
log show --predicate 'process == "Claude Island"' --last 2m --style compact

# RIGHT
log show --predicate 'process == "Claude Island"' --last 2m --style compact --info --debug
```

For `log stream`, use `--level debug` to include everything:

```bash
log stream --predicate 'process == "Claude Island"' --level debug --style compact
```

## Common recipes

### Historical lookup (finished events)

```bash
# Last 5 minutes, all levels
/usr/bin/log show --predicate 'process == "Claude Island"' --last 5m --style compact --info --debug

# Filter by category (see list below)
/usr/bin/log show --predicate 'subsystem == "com.engels74.ClaudeIsland" AND category == "Parser"' \
    --last 5m --style compact --info --debug

# Filter by message keyword
/usr/bin/log show --predicate 'process == "Claude Island"' --last 5m --style compact --info --debug \
    | grep -iE 'rewind|clear|history loaded|loadFromFile'
```

### Live tail (ongoing debugging)

```bash
# Stream everything
log stream --predicate 'process == "Claude Island"' --level debug --style compact

# Stream only a category
log stream --predicate 'subsystem == "com.engels74.ClaudeIsland" AND category == "Session"' \
    --level debug --style compact
```

Prefer the `Monitor` tool for long-running streams during a debugging session — each matching line becomes a notification, and the output won't flood the conversation.

## Shell caveats

- In `zsh`, the bare command `log` may conflict with a builtin/alias. Use the absolute path **`/usr/bin/log`** if you see `too many arguments` or similar.
- Use `--style compact` for one-line-per-event. The default `syslog` style wastes screen.
- `--last` accepts `Ns`, `Nm`, `Nh`, `Nd` (seconds/minutes/hours/days).

## Logger categories in this codebase

Each file typically owns one category. Filter on `category == "..."` to scope noise:

| Category | Source area | What to look for |
|---|---|---|
| `ChatView` | `UI/Views/ChatView.swift` | chat rendering, scroll, load task decisions |
| `Session` | `Services/State/SessionStore.swift` | `Clear:`, `Rewind:`, session state mutations |
| `Parser` | `Services/Session/ConversationParser.swift` | `Rewind detected: X → Y messages`, `/clear detected` |
| `Rewind` | `Services/Session/RewindWatcher.swift` | external JSONL rewind watcher |
| `Interrupt` | `Services/Session/JSONLInterruptWatcher.swift` | interrupt detection |
| `Hooks` | `Services/Hooks/HookSocketServer.swift` | incoming hook events over Unix socket |
| `HookInstaller` | `Services/Hooks/HookInstaller.swift` | hook script install/update |
| `Approval` | `Services/Tmux/ToolApprovalHandler.swift` | approve/deny dispatch to tmux |
| `ProcessExecutor` | `Services/Shared/ProcessExecutor.swift` | shelled-out processes |
| `ClaudeAPIService` | `Services/TokenTracking/ClaudeAPIService.swift` | Anthropic API calls, OAuth |
| `TokenTrackingManager` | `Core/TokenTrackingManager.swift` | usage/limit tracking |
| `CLIVersionDetector` | `Services/TokenTracking/CLIVersionDetector.swift` | Claude CLI version probing |
| `PythonRuntimeDetector` | `Services/Hooks/PythonRuntimeDetector.swift` | Python runtime detection for hooks |
| `PythonRuntimeAlert` | `Services/Hooks/PythonRuntimeAlert.swift` | Python runtime user alerts |
| `AppDelegate` | `App/AppDelegate.swift` | app lifecycle, install, window setup |
| `NotchWindowController` | `UI/Window/NotchWindowController.swift` | notch window lifecycle |
| `NotchDragController` | `Core/NotchDragController.swift` | detach drag gesture |
| `DetachedNotchView` | `UI/Views/DetachedNotchView.swift` | detached panel behavior |
| `NotchMenuView` | `UI/Views/NotchMenuView.swift` | menu view interactions |
| `Window` | `Services/Window/*.swift` | window finding/focusing |
| `TerminalFocuser` | `Services/Window/TerminalFocuser.swift` | terminal focus dispatch |
| `GlobalHotkey` | `Core/GlobalHotkeyManager.swift` | global hotkey registration/fire |
| `AccessibilityPermission` | `Core/AccessibilityPermissionManager.swift` | AX permission prompts |
| `ReleaseService` | `Services/Release/ReleaseService.swift` | Sparkle update flow |

## Canonical diagnostic phrases

Patterns worth grepping when something's wrong. Each one was load-bearing in a real bug at some point:

- **`Rewind detected: X → Y messages (active chain)`** — `/rewind` detection in `ConversationParser`. If it fires on every sync with small `X → Y`, the `parentMap` active-chain walk is terminating early (e.g., parent chain weaves through `attachment`/`system`/`file-history-snapshot` messages that the parser doesn't register). Symptom: chat history silently truncated to 1–3 items.
- **`Rewind: reset chatItems from N, rebuilding from M messages`** — `SessionStore.processFileUpdate` responding to the parser's rewind flag. Pair it with the `Parser` line above to see the reset happen.
- **`Clear: reset chatItems from N to M`** — `/clear` handler in `SessionStore`. Legitimate when the user actually ran `/clear`; suspicious if it fires unexpectedly.
- **`/clear detected (new), will notify UI`** — Parser side of the same event.
- **`History loaded: inferred phase .waitingForInput from lastMessageRole=...`** — `processHistoryLoaded` ran successfully. Absence suggests `loadHistoryFromFile` was never called or its session-dict guard tripped.
- **`Invalid transition: <phase> -> <phase>, ignoring`** — `SessionState.phase` state-machine rejected a hook transition. Usually a hint that events arrived out of order.

## Verifying which build is actually running

When a fix doesn't seem to apply, check you're actually running the rebuilt binary:

```bash
ps aux | grep -i "claude island" | grep -v grep
```

Look at the path:
- `/Users/apple/Desktop/work/claude-island/build/export/Claude Island.app/...` — release build from `./scripts/build.sh`
- `.../Library/Developer/Xcode/DerivedData/ClaudeIsland-*/Build/Products/Debug/...` — Xcode debug build

They are built from the same source tree but live at different paths. `killall "Claude Island"` + `open "build/export/Claude Island.app"` launches the release build; running from Xcode launches the Debug build. If you edit + rebuild via CLI but Xcode autobuild also runs, you may still land on the Debug variant — check the ps output to confirm.

## Enabling private data in log output (when needed)

`Logger` arguments marked `privacy: .private` (the default for interpolations) redact as `<private>` in logs. If you need to see redacted fields temporarily during development, the codebase already uses `privacy: .public` for IDs/paths in most places. To globally unmask private fields on a dev machine:

```bash
sudo log config --mode "private_data:on"
# undo
sudo log config --mode "private_data:off"
```

Do not leave this on outside development.

## When `log show` returns nothing at all

Checklist before assuming silence means no events:

1. `--info --debug` flags passed? (most common miss)
2. Process actually running? (`ps aux | grep -i "claude island"`)
3. Predicate syntax correct? Try `--predicate 'process == "Claude Island"'` without subsystem first.
4. Time window wide enough? Start with `--last 10m`, narrow later.
5. Category name typo? (exact-match, case-sensitive — see table above).
6. In `zsh`, is `log` shadowed? Use `/usr/bin/log`.
