# Feature: Warp Terminal 精确 Tab 跳转

## 问题

当前「跳转到终端」功能通过 `NSRunningApplication.activate()` 激活终端应用。对于 Warp 终端，所有 tab 共享同一个进程 PID，`activate()` 只能将 Warp 带到前台，无法定位到运行 Claude 的具体 tab。

## 目标

从 Claude Island 面板点击「跳转终端」时，精确切换到对应 Claude 会话所在的 Warp tab。

## 调研结论

### Warp 自身能力

| 接口 | 可用性 | 备注 |
|------|--------|------|
| AppleScript 字典 | 无 | [Issue #3364](https://github.com/warpdotdev/Warp/issues/3364), [Issue #1228](https://github.com/warpdotdev/Warp/issues/1228) |
| `warp://` URI Scheme | 仅 new_window/new_tab/launch | 无法切换已有 tab — [官方文档](https://docs.warp.dev/terminal/more-features/uri-scheme) |
| `oz` CLI (原 `warp-cli`) | 仅 Cloud Agent 管理 | 无终端/tab 控制 — [官方文档](https://docs.warp.dev/reference/cli/cli) |
| Accessibility API | 不可用 | Warp 用 Rust + Metal GPU 渲染，AX 树为空 — [Issue #4009](https://github.com/warpdotdev/Warp/issues/4009) |
| 键盘快捷键 | Cmd+1~9 切换 tab | 但无法从外部获知 tab 索引 |

### 根本原因

Warp 完全绕过 AppKit，使用自定义 Rust UI 框架 + Metal 着色器渲染。系统 Accessibility 树在窗口层级以下为空 — 无 tab 元素、无标题属性、无法遍历。Warp 团队确认「目前没有解决方案」。

### 已验证的可行能力

#### 1. OSC 转义序列设置 Tab 标题（已验证 ✅）

通过向终端 TTY 写入 OSC 0 转义序列，可动态设置 Warp tab 标题：

```bash
# 设置标题
printf '\033]0;Title\007' > /dev/ttysXXX

# 清除标题（恢复 Warp 自动标题）
printf '\033]0;\007' > /dev/ttysXXX
```

#### 2. tmux 场景下的 TTY 层级（已验证 ✅）

**关键发现**：tmux 环境下存在两层 TTY，必须写入正确的 TTY 才能控制 Warp tab 标题：

```
tmux list-clients -F "#{client_tty} #{client_session}"
→ /dev/ttys032 claude    ← Warp tab 的真正 TTY (client TTY)

tmux list-panes -a -F "#{pane_tty}"
→ /dev/ttys033           ← tmux pane 内部 TTY (被 tmux 拦截)
```

- **Client TTY** (`/dev/ttys032`): tmux 客户端连接到终端的 TTY → 写入此 TTY 可控制 Warp tab 标题 ✅
- **Pane TTY** (`/dev/ttys033`): tmux 为 pane 分配的伪终端 → 写入被 tmux 拦截，Warp 看不到 ❌

**获取 client TTY 的方法**：

```python
# Python 中获取 tmux client TTY
import subprocess
result = subprocess.run(
    ["tmux", "list-clients", "-F", "#{client_tty} #{client_session}"],
    capture_output=True, text=True
)
# 解析输出，按 session 名匹配找到对应 client TTY
```

#### 3. TTY 写入可跨进程工作（已验证 ✅）

从任意进程（不必是目标 tab 内的进程）写入 TTY 设备文件即可改变 tab 标题。这意味着 Swift app 端（`TerminalFocuser`）可以直接写入 TTY 实现闪烁，无需通过 hook。

## 方案设计

### 方案：Hook 标记 + 闪烁引导（推荐实施）

**核心思路**：通过 hook 让每个 Claude 会话的 tab 标题实时反映状态，跳转时闪烁标题引导用户注意力。

#### 第一步：通过 Hook 设置 Tab 标题

在 `claude-island-state.py` 中，根据会话状态动态设置 Warp tab 标题：

```
SessionStart    → "🤖 Claude: {project_name}"
Processing      → "⚡ Claude: {project_name}"
WaitingForInput → "⏸ Claude: {project_name}"
WaitingApproval → "🔔 Claude: {project_name}"
SessionEnd      → "" (清除，恢复 Warp 自动标题)
```

**实现位置**: `claude-island-state.py` → `main()` → 在 `send_event()` 后写入 TTY

```python
def get_terminal_tty(tty: str | None) -> str | None:
    """Get the actual terminal TTY, resolving through tmux if needed.

    In tmux, the hook's TTY is the pane TTY (intercepted by tmux).
    We need the client TTY (connected to the actual terminal) to
    control the tab title.

    Args:
        tty: The hook process's TTY path

    Returns:
        The terminal's real TTY path, or the original TTY if not in tmux
    """
    if not tty:
        return None

    # Check if we're inside tmux
    if not os.environ.get("TMUX"):
        return tty  # Not in tmux, use directly

    # In tmux: find the client TTY for our session
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "#{client_tty}"],
            capture_output=True, text=True, timeout=2, check=False,
        )
        if client_tty := result.stdout.strip():
            return client_tty
    except (subprocess.TimeoutExpired, OSError):
        pass

    return tty  # Fallback


def update_tab_title(status: str, cwd: str, tty: str | None) -> None:
    """Update terminal tab title based on session status."""
    terminal_tty = get_terminal_tty(tty)
    if not terminal_tty:
        return

    project = os.path.basename(cwd) if cwd else "unknown"
    title_map = {
        "waiting_for_input":    f"⏸ Claude: {project}",
        "processing":           f"⚡ Claude: {project}",
        "waiting_for_approval": f"🔔 Claude: {project}",
        "compacting":           f"📦 Claude: {project}",
        "ended":                "",  # Clear title
    }
    title = title_map.get(status, f"🤖 Claude: {project}")
    try:
        with open(terminal_tty, "w") as f:
            f.write(f"\033]0;{title}\007")
    except OSError:
        pass
```

#### 第二步：跳转时闪烁目标 Tab 标题

当用户点击「跳转终端」时：

1. `TerminalFocuser` 激活 Warp（现有逻辑）
2. Swift 端直接向 TTY 写入闪烁序列引导注意力

**TTY 来源**：`SessionState.tty` 已由 hook 传入 Swift 端。对于 tmux 场景，hook 应传入 client TTY（第一步中已解析）。

```swift
// TerminalFocuser.swift
func flashTabTitle(tty: String, projectName: String) async {
    let flash = "\u{1b}]0;\u{1f449}\u{1f449}\u{1f449} Claude: \(projectName) \u{1f448}\u{1f448}\u{1f448}\u{07}"
    let restore = "\u{1b}]0;\u{1f916} Claude: \(projectName)\u{07}"
    guard let handle = FileHandle(forWritingAtPath: tty) else { return }
    defer { handle.closeFile() }
    handle.write(Data(flash.utf8))
    try? await Task.sleep(for: .milliseconds(500))
    handle.write(Data(restore.utf8))
}
```

**调用点**：`ChatView.focusTerminal()` 中，`activate()` 成功后调用。

#### 第三步（可选增强）：SessionState 传递 terminal TTY

Hook 端解析 tmux client TTY 后，通过新增字段 `terminal_tty` 传给 Swift 端，与现有 `tty`（进程 TTY）区分：

```python
# SessionState 新增字段
terminal_tty: str | None  # 终端真实 TTY（tmux 下为 client TTY）
```

### 数据流

```
[Hook 设置标题]
  claude-island-state.py
    → 状态变化触发
    → get_terminal_tty(tty)
      → 非 tmux: 直接返回 tty
      → tmux: tmux display-message -p "#{client_tty}" → client TTY
    → open(terminal_tty).write("\033]0;Title\007")
    → Warp tab 标题更新

[跳转时闪烁]
  ChatView.focusTerminal()
    → TerminalFocuser.focusTerminal(forClaudePID:)
      → NSRunningApplication.activate()  (激活 Warp)
      → flashTabTitle(tty:projectName:)  (直接写 TTY 闪烁标题)

[TTY 层级 - tmux 场景]
  Warp Tab (/dev/ttys032)  ← client TTY (控制 tab 标题)
    └─ tmux server
        └─ tmux pane (/dev/ttys033)  ← pane TTY (被 tmux 拦截)
            └─ claude (PID 12345)
```

## 适用范围

| 终端 | Tab 标题设置 | 精确 Tab 切换 | 闪烁引导 | 备注 |
|------|-------------|--------------|---------|------|
| **Warp** | ✅ OSC 0 | ❌ | ✅ | AX 树为空，仅视觉辅助 |
| **Terminal.app** | ✅ OSC 0 | ✅ AppleScript | ✅ | `tell app "Terminal" to set selected of tab N to true` |
| **iTerm2** | ✅ OSC 0 | ✅ AppleScript / Python API | ✅ | 完整自动化支持 |
| **Ghostty** | ✅ OSC 0 | ❌ | ✅ | 同 Warp 类似限制 |
| **Kitty** | ✅ OSC 0 | ✅ `kitty @ focus-tab` | ✅ | Remote control 协议 |
| **WezTerm** | ✅ OSC 0 | ✅ Lua API / CLI | ✅ | `wezterm cli activate-tab` |
| **VS Code** | N/A | N/A | N/A | 集成终端，不适用 tab 概念 |

## 实施计划

### Phase 1: Hook 设置 Tab 标题（低成本，高价值）

- **修改**: `claude-island-state.py` — 新增 `get_terminal_tty()` 和 `update_tab_title()`
- **工作量**: ~2 小时
- **效果**: 所有终端 tab 实时显示 Claude 会话状态和项目名，用户可视觉识别

### Phase 2: 跳转时闪烁标题（中等成本）

- **修改**: `TerminalFocuser.swift` — 新增 `flashTabTitle()` 方法
- **修改**: `ChatView.swift` — `focusTerminal()` 中调用闪烁
- **修改**: `SessionState` — 新增 `terminalTTY` 字段（tmux 场景下与 `tty` 不同）
- **工作量**: ~3 小时
- **效果**: 跳转时闪烁目标 tab 标题，用户快速定位

### Phase 3: 支持精确切换的终端（长期）

- **新增**: `TerminalTabSwitcher` 协议 + 各终端实现
- **支持**: Terminal.app (AppleScript), iTerm2 (AppleScript), Kitty (remote control), WezTerm (CLI)
- **工作量**: ~1 天
- **效果**: 支持脚本化的终端可实现真正的精确 tab 跳转

> **Warp 的 Phase 3 已实现，走独立路径**：见 [`warp-cli-agent-notification.md`](./warp-cli-agent-notification.md)。
> Warp 没有 AppleScript / remote-control，走 OSC 777 `warp://cli-agent` CLI Agent 协议
> + 合成 `Shift+Cmd+G`，让 Warp 内部的 `focus_tab()` 完成真正的 tab 切换。
> 其他终端仍按本文计划的 `TerminalTabSwitcher` 协议推进。

## 配置项

```swift
// AppSettings.swift
var enableTabTitleTracking: Bool  // 是否通过 hook 设置 tab 标题 (默认 true)
var enableTabFlashOnFocus: Bool   // 跳转时是否闪烁标题 (默认 true)
var tabTitleFormat: String        // 自定义格式，如 "{emoji} Claude: {project}"
```

## 风险与限制

1. **Warp 的 `WARP_DISABLE_AUTO_TITLE`**: 如果用户未设置此环境变量，Warp 可能覆盖我们设置的标题。需要在 hook 中 `export WARP_DISABLE_AUTO_TITLE=true`，或在文档中提示用户。
2. **TTY 写入权限**: Hook 进程和 Swift app 通常有 TTY 写入权限，但在某些沙盒环境下可能受限。
3. **非 Warp 终端影响**: 标题设置使用通用 OSC 0 序列，会影响所有终端的 tab 标题。用户若不需要可通过设置关闭。
4. **闪烁体验**: 标题闪烁可能干扰用户，需提供关闭选项。
5. **tmux client TTY 解析**: `tmux display-message` 需要 tmux 可用且 session 处于 attached 状态。Detached session 没有 client TTY。
