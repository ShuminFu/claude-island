# Feature: Warp CLI Agent 原生通知与 Tab 跳转

## 背景

`docs/features/warp-tab-focus.md` 曾给出结论：Warp 因为用 Rust + Metal 自绘 UI，**AppleScript/AX/URI scheme 都无法切换已有 tab**，Claude Island 只能退而求其次用 OSC 0 闪烁标题做视觉引导。

但 [`claude-code-warp`](https://github.com/anthropics/claude-code/tree/main/plugins/warp) 插件用不到 200 行 bash 就做到了：

1. 通知中心弹出横幅；
2. Warp tab 标题旁显示状态指示灯；
3. **`Shift+Cmd+G` 直接跳到最近一次 agent 事件所在的 tab**。

它没用任何 Warp 私有接口——全部通过 **OSC 777 + `warp://cli-agent` title + JSON body** 这条跨终端的字节流协议实现。协议是 Warp 公开约定的，`warp://cli-agent` 这个 URI-form title 是唯一的厂商扩展点，其余都是标准 xterm OSC。

本 feature 把这条路径接入 Claude Island 的 hook，获得「真正的 Warp tab 跳转」能力，作为 `warp-tab-focus.md` Phase 3 的具体实现。

## 目标

- 复用 Claude Island 已有 hook 管线，**额外**向 TTY 写入 OSC 777 `warp://cli-agent` 帧；
- 让 Warp 按其 CLI Agent 子系统自然消费事件，把 tab 加入 `wakeable_tabs`；
- 使 `Shift+Cmd+G`（Warp 内建快捷键 `workspace:jump_to_latest_toast`）能跳到 Claude Island 管辖的 Claude Code tab；
- 可选：让 Claude Island 面板的「跳转终端」按钮**也**走这条路径，借 Warp 内部动作 + 模拟按键实现真正的 tab 切换（而非只激活应用）。

## 核心机制回顾

```
claude-island-state.py
       │
       │  (已有) socket → ClaudeIsland.app  → 通知 / 内部状态机
       │
       └─ (新增) printf '\033]777;notify;warp://cli-agent;<json>\007' > /dev/<terminal_tty>
                                    │
                                    ▼
                            Warp tab pty master 端读到
                                    │
                                    ▼
                     Warp CLI Agent 子系统解析 JSON → 更新 TabState
                                    │
                         ┌──────────┴──────────┐
                         ▼                     ▼
                   弹系统通知          tab 加入 wakeable_tabs
                   (UNUserNotificationCenter)        │
                         │                     │
                         ▼                     ▼
                用户点通知 → focus_tab   用户按 Shift+Cmd+G → focus_tab
```

**tab 归属由 pty 天然带过来**：我们写进 `/dev/ttysNNN`，Warp 持有该 pty 的 master fd 的那个 `TabController` 就会把这条事件归到自己的 tab。不需要在 JSON 里说「我是 tab 几」，Warp 也不看。

## 与 Claude Island 现状的契合点

| 现有能力 | 复用方式 |
|---|---|
| `claude-island-state.py` 已被 hook 调用，覆盖全部生命周期事件 | 在现有 `main()` 里加一次 OSC 777 写入，和 `update_tab_title(OSC 0)` 并列 |
| `get_terminal_tty()` 已解析 tmux client TTY | OSC 777 写入使用**同一个** `terminal_tty`，tmux 场景直接可用 |
| `SessionState.status`（`processing` / `waiting_for_input` / `waiting_for_approval` / `compacting` / `ended`） | 映射到 CLI Agent `event` 字段，见下表 |
| hook 中已收集 `cwd` / `project name` / `tool_name` / `tool_input` | 直接塞进 payload，无新增数据源 |
| Swift 端 `TerminalFocuser.flashTabTitle` 已会写 TTY | 可复用同一写入管线从 Swift 端触发「focus this tab」 |

## 设计

### 1. Hook 端：新增 `emit_warp_cli_agent_event`

新增 Python 函数（加到 `claude-island-state.py`，与 `update_tab_title` 并列）：

```python
WARP_CLI_AGENT_TITLE = "warp://cli-agent"
WARP_PROTOCOL_VERSION = 1

# status → CLI Agent event 名称
STATUS_TO_CLI_AGENT_EVENT: dict[str, str] = {
    "session_start":         "session_start",
    "processing":            "user_prompt_submit",
    "running_tool":          "post_tool_use",
    "waiting_for_input":     "idle_prompt",
    "waiting_for_approval":  "permission_request",
    "compacting":            "user_prompt_submit",   # 视觉上保持 running
    "ended":                 "stop",
}


def should_emit_warp_cli_agent() -> bool:
    """Gate: only emit when running inside Warp and protocol is advertised."""
    if os.environ.get("TERM_PROGRAM") != "WarpTerminal":
        return False
    # Protocol version advertised by Warp itself — absence means too old.
    return bool(os.environ.get("WARP_CLI_AGENT_PROTOCOL_VERSION"))


def emit_warp_cli_agent_event(
    state: SessionState,
    terminal_tty: str | None,
    /,
) -> None:
    """Write an OSC 777 `warp://cli-agent` frame to the terminal TTY.

    Warp's CLI Agent subsystem consumes this to:
      - Render an inline status dot on the tab,
      - Post a native macOS notification (for idle/permission/stop events),
      - Mark the tab as "wakeable" so Shift+Cmd+G can jump to it.
    """
    if not terminal_tty or not should_emit_warp_cli_agent():
        return

    cli_event = STATUS_TO_CLI_AGENT_EVENT.get(state.status)
    if not cli_event:
        return

    # Negotiate protocol version (min of plugin & Warp)
    try:
        warp_v = int(os.environ.get("WARP_CLI_AGENT_PROTOCOL_VERSION", "1"))
    except ValueError:
        warp_v = 1
    version = min(WARP_PROTOCOL_VERSION, warp_v)

    project = Path(state.cwd).name if state.cwd else "unknown"
    payload: dict[str, object] = {
        "v": version,
        "agent": "claude",
        "event": cli_event,
        "session_id": state.session_id,
        "cwd": state.cwd,
        "project": project,
    }

    # Per-event enrichment (mirrors build-payload.sh conventions)
    if cli_event == "permission_request":
        payload["tool_name"] = state.tool or ""
        payload["tool_input"] = state.tool_input or {}
        payload["summary"] = _permission_summary(state)
    elif cli_event == "post_tool_use":
        payload["tool_name"] = state.tool or ""
    elif cli_event == "idle_prompt":
        payload["summary"] = state.message or "Claude is waiting for input"

    body = json.dumps(payload, separators=(",", ":"))
    frame = f"\033]777;notify;{WARP_CLI_AGENT_TITLE};{body}\007"
    try:
        with open(terminal_tty, "w") as f:
            f.write(frame)
    except OSError:
        pass  # silent: no controlling TTY / permission denied
```

挂接点（`main()`，紧贴 `update_tab_title` 之后）：

```python
update_tab_title(status, cwd, terminal_tty)
emit_warp_cli_agent_event(state, terminal_tty)   # ← 新增
```

两条 OSC 用**同一个** `terminal_tty`，保证 tmux 下归属正确。

### 2. Event / Status 映射

| Claude Island `SessionPhase` | hook `status` | CLI Agent `event` | Warp 侧效果 |
|---|---|---|---|
| `.idle` (session 开始) | `session_start` | `session_start` | 绑定 session_id，tab 标记为 agent tab |
| `.processing` | `processing` | `user_prompt_submit` | tab dot = running |
| `.processing` (工具执行) | `running_tool` | `post_tool_use` | tab dot = running |
| `.waitingForInput` | `waiting_for_input` | `idle_prompt` | 弹系统通知 + tab dot = waiting，加入 `wakeable_tabs` |
| `.waitingForApproval` | `waiting_for_approval` | `permission_request` | 弹系统通知 + tab dot = needs_permission，加入 `wakeable_tabs` |
| `.compacting` | `compacting` | `user_prompt_submit` | 保持 running 状态（CLI Agent 协议无对应事件） |
| `.ended` | `ended` | `stop` | 弹系统通知 + tab dot = idle |

只有 `idle_prompt` / `permission_request` / `stop` 会触发 Warp 端的 `UNUserNotificationCenter`；`user_prompt_submit` / `post_tool_use` 只悄悄更新状态——与 Claude Island 自己的 notch 分工互补：

- **Claude Island notch**：所有细粒度活动（工具运行、token 消耗、状态轮播）；
- **Warp 原生通知**：仅「需要人」的三类信号，承担「Claude Island 不在前台时把用户拉回来」的职责。

### 3. Swift 端：真正的 Warp tab 跳转

`warp-tab-focus.md` 明确说「Warp 无法精确切换 tab」。加入 CLI Agent 协议后，**有了**。

#### 思路

1. Hook 已经把目标 tab 放进了 `wakeable_tabs`（`waiting_for_input` / `waiting_for_approval` / `ended` 都会）。
2. 若目标 tab **不是**最近一次 agent 事件的所在 tab，先从 Swift 端向目标 tab 的 TTY 再发一次 `idle_prompt` OSC 777——把它「顶」成最新。
3. 调 Warp 内建 action `workspace:jump_to_latest_toast`——也就是 `Shift+Cmd+G`，通过 CGEvent 合成按键。
4. Warp 内部会执行完整的 `focus_tab()`：`NSApp.activate()` + `window.makeKeyAndOrderFront` + `selected_tab = N`。

#### 新增方法

加到 `TerminalFocuser.swift`：

```swift
/// Jump to the specific Warp tab that hosts the given Claude session.
///
/// Requires the session's terminal TTY (client TTY in tmux) to be known.
/// Works by re-emitting an OSC 777 `warp://cli-agent` frame so the target
/// tab becomes Warp's "most recent agent event" tab, then synthesizing
/// `Shift+Cmd+G` to invoke Warp's `workspace:jump_to_latest_toast`.
///
/// - Parameters:
///   - tty: Terminal TTY name (e.g., "ttys032"), without `/dev/` prefix.
///   - sessionID: Claude session UUID (used only for Warp-side correlation).
///   - projectName: Used in the OSC payload's `project` field.
/// - Returns: `true` when both the OSC emit and the keystroke synthesis
///   succeeded (does not guarantee the tab actually came forward — we
///   can't observe Warp's internal state).
@MainActor
func jumpToWarpTab(
    tty: String,
    sessionID: String,
    projectName: String
) async -> Bool {
    // 1. Re-emit idle_prompt so the target tab becomes the latest agent toast.
    guard await self.emitWarpCLIAgentIdle(
        tty: tty,
        sessionID: sessionID,
        projectName: projectName,
    ) else { return false }

    // Tiny delay so Warp's pty reader picks up the frame before the
    // keystroke arrives on the main thread (Warp processes both on its
    // main thread; the ordering matters).
    try? await Task.sleep(for: .milliseconds(50))

    // 2. Activate Warp (idempotent — click-to-notification path also does this).
    NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable")
        .first?.activate()

    // 3. Synthesize Shift+Cmd+G.
    return self.postKeystroke(
        keyCode: 0x05,  // 'g'
        flags: [.maskCommand, .maskShift],
    )
}
```

两个私有辅助：

- `emitWarpCLIAgentIdle(tty:sessionID:projectName:)` — 复用 `flashTabTitle` 的 `FileHandle` 写法，body 用固定模板 `{"v":1,"agent":"claude","event":"idle_prompt",...}`。
- `postKeystroke(keyCode:flags:)` — `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 组合键下+键上，`post(tap: .cghidEventTap)`。

**权限**：合成按键需要 Accessibility 权限。Claude Island 已有 `AccessibilityWarningModule`，在这里复用——无权限时走回退：`NSRunningApplication.activate()` 只把 Warp 拉到前台，但落在哪个 tab 看用户。

#### `focusTerminal(forClaudePID:)` 接线

在 `activateTerminal(...)` 判断分支里，命中 Warp 时优先走 `jumpToWarpTab`：

```swift
if command.contains("Warp.app"), let tty = session.terminalTTY, !tty.isEmpty {
    Task { await jumpToWarpTab(tty: tty, sessionID: session.id, projectName: session.projectName) }
    return true
}
// 其他终端走既有逻辑（AppleScript / activate() + flashTabTitle）
```

### 4. 与用户通知的分工设置

避免双重通知轰炸，新增两个开关（挂在 `AppSettings`）：

| 设置键 | 默认 | 说明 |
|---|---|---|
| `warpCLIAgentEnabled` | 检测到 `TERM_PROGRAM=WarpTerminal` 时为 `true` | 是否向 Warp 发 OSC 777 |
| `warpCLIAgentNotificationMode` | `.both` | `.warpOnly` / `.islandOnly` / `.both` |

`.warpOnly` 时，Claude Island 内部仍然收 hook 事件（notch 动画、tokens 更新继续工作），只是不调 `NSUserNotificationCenter` 弹横幅——把弹通知的活让给 Warp。`.islandOnly` 则不向 Warp 发 OSC 777，维持既有行为。

hook 端用 `CLAUDE_ISLAND_WARP_CLI_AGENT=1/0` 环境变量读到决策结果；Swift app 在启动时把用户选择写进这个环境变量（通过修改 `ClaudeIsland.app` 启动 Claude 的包装器或用户 `~/.zshrc` 提示，**TBD**）。

### 5. 降级与兼容

照搬 `claude-code-warp` 的 `should-use-structured.sh` 思路：

- **老版本 Warp**（没设 `WARP_CLI_AGENT_PROTOCOL_VERSION`）：`should_emit_warp_cli_agent()` 返回 `False`，完全不发 OSC 777，Claude Island 的 OSC 0 标题更新照常工作。
- **已知有 bug 的 Warp 版本**：维护一个黑名单（硬编码版本号），命中时降级到不发。Warp 官方后续修复版本可以从黑名单移除。
- **非 Warp 终端**：`TERM_PROGRAM != "WarpTerminal"`，不发——对 iTerm2 / Terminal.app / Ghostty 等零影响。OSC 777 在这些终端里会被当作普通通知或被忽略，不会造成乱码，但我们依然只在 Warp 下启用，避免意料之外的系统通知。
- **tmux detached session**：`get_terminal_tty` 取不到 client TTY 时返回 None，两路 OSC 都 no-op。

### 6. 安全性

完全继承 `claude-code-warp` 的安全模型：

- **谁能写**：只有自己能打开自己的 `/dev/ttysNNN`（tty 组权限）——其他用户伪造不了你的 tab 通知。
- **谁能让 Warp 抢前台**：macOS 规则没变——只有「响应用户主动交互」的路径能激活 app。我们合成的 `Shift+Cmd+G` 之所以能激活，是因为 Warp 自己已经被 `NSRunningApplication.activate()` 拉上来了，Shift+Cmd+G 只是在已激活的 Warp 进程内选 tab。Claude Island 在后台状态下不能「强行」把 Warp 抢到前台——这就是为什么第一步要主动激活 Warp。
- **合成按键的权限**：需要 Accessibility 授权，这是 macOS 用户同意的显式授权——与 Claude Island 既有「跳转终端」按钮的权限要求一致。

## 数据流总览

```
[状态变更 hook 被 Claude Code 触发]
  claude-island-state.py
    ├─ send_event(state)                         → Unix socket → ClaudeIsland.app
    ├─ update_tab_title(status, cwd, tty)        → OSC 0 标题
    └─ emit_warp_cli_agent_event(state, tty)     → OSC 777 → Warp CLI Agent
                                                        ├─ 更新 tab dot
                                                        └─ 触发系统通知 (idle_prompt/permission/stop)

[面板点击「跳转终端」]
  ChatView.focusTerminal()
    └─ TerminalFocuser.focusTerminal(forClaudePID:)
         └─ activateTerminal(...)
             ├─ 非 Warp → 既有 AppleScript / activate + flashTabTitle
             └─ Warp →
                  1. emitWarpCLIAgentIdle(tty, ...)   ← 新 OSC 777 `idle_prompt`，把目标 tab 顶为最新
                  2. Warp.activate()                   ← NSRunningApplication
                  3. CGEvent Shift+Cmd+G               ← Warp 内部 focus_tab()
                     → NSApp.activate + window.makeKeyAndOrderFront + selected_tab = N
```

## 文件变更预估

| 文件 | 变更 | 行数估算 |
|---|---|---|
| `ClaudeIsland/Resources/claude-island-state.py` | `+emit_warp_cli_agent_event`, `+should_emit_warp_cli_agent`, `+_permission_summary`, 挂接到 `main()` | +60 |
| `ClaudeIsland/Services/Window/TerminalFocuser.swift` | `+jumpToWarpTab`, `+emitWarpCLIAgentIdle`, `+postKeystroke`；`activateTerminal` 增加 Warp 分支 | +90 |
| `ClaudeIsland/Core/Settings.swift` | `+warpCLIAgentEnabled`, `+warpCLIAgentNotificationMode` 枚举 | +20 |
| `ClaudeIsland/UI/Views/NotchMenuView.swift` | Preferences 新加 Warp 整合一栏（三选一 radio） | +30 |
| `tests/` | OSC 777 frame 构造测试 + status→event 映射测试 | +60 |

## 实施阶段

### Phase 1 — Hook 端 OSC 777（最小可用）

- 仅加 `emit_warp_cli_agent_event` 与挂接点，默认启用（Warp 环境下）；
- 用户立刻获得：Warp 状态点、原生系统通知、`Shift+Cmd+G` 跳 tab；
- 无 Swift 改动，风险最低。

### Phase 2 — Swift `jumpToWarpTab`

- `TerminalFocuser` 加 Warp 分支；
- 面板「跳转终端」按钮在 Warp 下从「仅激活 Warp」升级为「跳到具体 tab」；
- 引入 Accessibility 权限依赖路径。

### Phase 3 — 通知分工设置

- Settings UI 加三选一；
- hook 端读环境变量，`.warpOnly` / `.islandOnly` 模式通过抑制 Claude Island 自己的通知来实现。

### Phase 4 — 版本黑名单与遥测

- 参照 `should-use-structured.sh` 维护已知坏版本；
- 失败时记 `os.Logger`，便于用户反馈。

## 风险与限制

1. **Warp CLI Agent 协议可能变更**：协议是 Warp 约定但未文档化。通过 `WARP_CLI_AGENT_PROTOCOL_VERSION` 协商，短期内稳定；长期需要跟踪 Warp 更新。
2. **按键合成依赖 Accessibility 权限**：未授权时降级到「仅 `activate()`」，tab 跳转无效——需要在 UI 明示引导授权。
3. **Tab 顺序依赖「最新 toast」启发式**：多个 Claude 会话同时待命时，`Shift+Cmd+G` 跳到哪个取决于谁最后发事件。Phase 2 的「重发 idle_prompt 把目标顶成最新」是正面利用这个行为，但用户若在其他 Claude tab 里有活动就可能错位——接受这个限制，和 Warp 原生行为一致。
4. **tmux detached session**：没有 client TTY，整条通路静默失败，和既有 OSC 0 标题更新行为一致。
5. **双通知**：默认 `.both` 时，Claude Island 的内部通知 + Warp 的系统通知会同时出现。默认模式下用户能从 UI 改到 `.warpOnly` 或 `.islandOnly`，但第一次体验可能吵——`warpCLIAgentNotificationMode` 的初始值建议后续观察用户反馈再调整。

## 与已有 `warp-tab-focus.md` 的关系

| 文档 | 定位 |
|---|---|
| `warp-tab-focus.md` | 基础设施：hook 解析 client TTY，OSC 0 标题追踪，Swift 闪烁引导。Phase 3「精确切换」留白。 |
| **本文** | 填上 Phase 3：OSC 777 CLI Agent 协议 + 合成按键 → Warp 真正的 tab 跳转；并顺带接入 Warp 原生通知。 |

两个 feature **互补**，共用同一份 `get_terminal_tty()` 解析逻辑和 `SessionState.terminalTTY` 字段，不冲突。
