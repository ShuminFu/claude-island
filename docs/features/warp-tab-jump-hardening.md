# Feature: Warp Tab Jump 按钮可靠性加固

跟进文档：[`warp-cli-agent-notification.md`](./warp-cli-agent-notification.md)、[`warp-tab-focus.md`](./warp-tab-focus.md)。

## 背景

Phase 2 已经把 `TerminalFocuser.focus(session:)` 的 Warp 分支接到 `jumpToWarpTab`——理论上点击面板「跳转终端」按钮应当走完整的 OSC 777 `idle_prompt` → `Shift+Cmd+G` → Warp 内部 `focus_tab()` 链路，切到目标 tab。

实测症状：**按钮只把 Warp 拉到前台，停在上次浏览的 tab，不切换**。Warp 自己弹出的系统通知点一下却能精确切 tab——两条路径对用户行为完全一致，区别在背后走的机制：

| 路径 | 背后机制 | 是否依赖外部环境 |
|---|---|---|
| 点系统通知 | Warp 的 `UNUserNotificationCenter` 回调直接拿到 payload 中的 `session_id`，查自己的 `session_id → pty → tab` 绑定，调 `focus_tab()` | 否，纯进程内 |
| 点面板按钮 | 我们重发 `idle_prompt` 把目标 tab 顶成最新 toast → `activate()` Warp → 合成 `Shift+Cmd+G` → Warp 的 `workspace:jump_to_latest_toast` action → `focus_tab()` | **是**，见下 |

CLI Agent 协议没有「focus this session_id」命令——通知点击回调是 Warp 私有路径，外部无法冒名。我们只能走「最新 toast 启发式 + 合成快捷键」这条唯一公开路径。

## 根因分解

按钮路径包含四个隐含假设，任一不成立都会静默退化为「只激活 Warp」：

### 1. Accessibility 权限（主要原因）

`TerminalFocuser+Warp.swift:postKeystroke` 用 `CGEvent.post(tap: .cghidEventTap)`。未授权 Accessibility 时 macOS **不回报错**：`CGEvent` 构造仍然成功，`post` 默默丢弃事件，函数返回 `true`。

现有代码 (`TerminalFocuser+Warp.swift:141–153`) 只检查事件创建失败，检查不到投递失败——`Self.warpLogger.error("Shift+Cmd+G synthesis failed — Accessibility permission missing?")` 分支永远不会被触发。

Claude Island 有 `AccessibilityWarningModule`，但 `jumpToWarpTab` 路径没有复用它。

### 2. `activate()` 是异步的（次要原因）

`NSRunningApplication.activate()` 返回成功只表示请求被 WindowServer 接受，不代表 Warp 已经成为 frontmost。实测间隔 80ms 后 frontmost 仍可能是 Claude Island 的 `NotchPanel` 或上一个应用——合成的 `Shift+Cmd+G` 就会打到错的进程。

### 3. 用户可能重绑了 `Shift+Cmd+G`

Warp 默认把 `Shift+Cmd+G` 绑在 `workspace:jump_to_latest_toast`，但这是用户可改的。更常见的是 macOS 系统默认 `Shift+Cmd+G` = Find Previous——如果用户在 Warp 里把它改回 Find Previous，我们合成的键会触发搜索面板。

### 4. `session.terminalTTY` 可能为 nil

tmux detached session、hook 首次触达前的 session、Claude CLI 在非 pty 下启动——这些场景 `terminalTTY` 是 nil。`focus(session:)` 回退到 `tty`，但 `tty` 在 tmux 下是 pane TTY（被拦截），写 OSC 777 Warp 看不到。于是 `guard emitted else { return false }` 直接走通用 activate 分支，用户看到的就是「只到 Warp 前台」。

目前代码只在 `emit failed` 时打了一条 warning，没把「fell back」这件事明确标给用户。

## 设计

围绕上面四个假设各加一道检查/回退。目标不是把每个环节都变成 100% 可靠（那做不到——CLI Agent 协议本身不允许），而是**让失败模式可观测、可降级、可诊断**。

### 加固 1：AX 权限前置校验 + 用户引导

`jumpToWarpTab` 入口加 `AXIsProcessTrusted()` 短路：

```swift
guard AXIsProcessTrusted() else {
    Self.warpLogger.warning("jumpToWarpTab: AX not trusted — falling back to activate-only")
    // 仍然激活 Warp（总比什么都不做好），但同时把权限引导推到用户面前
    await AccessibilityWarningController.shared.surfaceIfNeeded(reason: .warpTabJump)
    _ = activateWarp()
    return false
}
```

`AccessibilityWarningModule` 已存在，但只在 notch 里显示。新增 `AccessibilityWarningController.surfaceIfNeeded(reason:)` 用于主动把 notch 打开一下（参考 `NotchViewModel.notchOpen(reason:)`）——只在用户**主动点击了跳转按钮却没授权**时触发，避免打扰。

**回退行为**：AX 未授权时至少保留现有「激活 Warp」的体验，等价于加固前。不比现在差。

### 加固 2：等 Warp 真的 frontmost 再合成按键

把 80ms 定时 sleep 换成轮询 `NSWorkspace.shared.frontmostApplication`：

```swift
private func waitForFrontmost(bundleID: String, timeout: Duration = .milliseconds(500)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
```

调用：

```swift
let warpBundleID = warp.bundleIdentifier ?? "dev.warp.Warp-Stable"
_ = warp.activate()
let becameFront = await waitForFrontmost(bundleID: warpBundleID)
if !becameFront {
    Self.warpLogger.warning("jumpToWarpTab: Warp did not become frontmost within 500ms — posting keystroke anyway")
}
```

最坏情况（Warp 被某些全屏 app 挡住无法被激活）下仍然投递按键，但日志能看出来事情不对。

### 加固 3：合成按键三通道（pid 定向 → 全局 tap → AppleScript）

**实测教训：** 从 Claude Island 的 `NSPanel(nonactivatingPanel)` 触发的 `CGEvent.post(tap: .cghidEventTap)`，即便 AX 已授权、Warp 已 frontmost，按键仍会被全局 HID 队列静默丢弃——日志四步全绿，Warp 毫无反应。排查过程见会话记录：OSC 写入成功、`waitForFrontmost=true`（~1ms 即满足，说明 Warp 本来就是 frontmost）、`postKeystroke` 返回 true——但 tab 不切。

Root cause 最终指向非激活 panel 与全局 HID tap 的交互——换成 `CGEventPostToPid` 直投 Warp 进程即可绕过。

因此三级优先顺序是：

```swift
func sendJumpToLatestToast(targetPID: pid_t?) async -> Bool {
    // 首选：直投 Warp 进程，绕开全局 HID 队列
    if let targetPID, postKeystroke(keyCode: 0x05, flags: [.maskCommand, .maskShift], targetPID: targetPID) {
        return true
    }
    // 回退 1：全局 tap（PID 未知或 postToPid 失败）
    if postKeystroke(keyCode: 0x05, flags: [.maskCommand, .maskShift], targetPID: nil) {
        return true
    }
    // 回退 2：System Events（部分 AX 配置下 CGEvent 创建返回 nil 但 AppleScript 仍工作）
    return await postKeystrokeViaAppleScript()
}

private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags, targetPID: pid_t?) -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else { return false }
    down.flags = flags; up.flags = flags
    if let targetPID {
        down.postToPid(targetPID); up.postToPid(targetPID)
    } else {
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    return true
}
```

Warp 没有公开 API 能让我们验证「tab 真的切了」，但我们至少能把**自己这一侧**的成功率提上去。

### 加固 4：`terminalTTY` 缺失时的诊断

`focus(session:)` 进入 Warp 分支前已经做了 nil 检查。现状是**静默**回退到通用分支。改为：

```swift
if let hostInfo, hostInfo.command.lowercased().contains("warp") {
    if let tty = session.terminalTTY ?? session.tty, !tty.isEmpty {
        return await jumpToWarpTab(tty: tty, sessionID: session.sessionID, projectName: session.projectName)
    }
    Self.logger.warning(
        "Warp detected but no TTY (sessionID=\\(session.sessionID), tmuxDetached=\\(session.isTmuxDetached ?? false)) — falling back to activate-only"
    )
}
// 既有通用分支
```

日志里能直接看到是 tmux detached 还是 hook 尚未跑过——省掉用户复现和排查的时间。

## 数据流（加固后）

```
用户点击「跳转终端」
  ChatView / ClaudeInstancesView / NotchViewModel
    → TerminalFocuser.focus(session:)
        └─ Warp 分支
             ├─ AXIsProcessTrusted() == false
             │     └─ AccessibilityWarningController.surfaceIfNeeded
             │        activate(Warp) → return false
             │
             ├─ terminalTTY == nil
             │     └─ logger.warning(reason)
             │        fall through to generic activate
             │
             └─ normal path
                   1. emitWarpCLIAgentIdle(tty, ...)
                   2. activate(Warp)
                   3. waitForFrontmost("dev.warp.Warp-Stable", timeout: 500ms)
                   4. sendJumpToLatestToast(targetPID: warpPID)
                         ├─ CGEventPostToPid(warpPID) → 成功返回
                         └─ CGEvent 不可用 → NSAppleScript keystroke
```

## 实际文件变更

| 文件 | 变更 |
|---|---|
| `ClaudeIsland/Services/Window/TerminalFocuser+Warp.swift` | AX 前置校验、`waitForFrontmost` 轮询、pid 定向 + 全局 tap + AppleScript 三级按键通道、逐步断点日志 |
| `ClaudeIsland/Services/Window/TerminalFocuser.swift` | Warp 已检出但无 TTY 时打 warning，不再静默回退 |
| `ClaudeIsland/Core/AccessibilityPermissionManager.swift` | 新增 `surfaceForWarpJumpIfNeeded()`，整进程生命周期只弹一次 |

未改 hook 端（`claude-island-state.py`），也未改 `warpCLIAgentEnabled` / `warpCLIAgentNotificationMode` 设置，不破坏向后兼容。单测未新增——`CGEventPostToPid` / `NSWorkspace.frontmostApplication` 都需要重写可注入抽象层才能 mock，收益不足以抵成本；现有 `WarpCLIAgentTests.swift` 里的注释已说明这一点。

## 实施阶段

### Phase 1 — 观测性

- 加 AX 权限校验前置、`terminalTTY == nil` 诊断日志、frontmost 轮询
- 不改按键投递路径
- 让用户能从 `log show --predicate 'subsystem == "com.engels74.ClaudeIsland" AND category == "WarpCLIAgent"'` 直接看到失败原因

### Phase 2 — pid 定向按键 + AppleScript 备选

- 首选 `CGEventPostToPid(warpPID)`，把按键塞进 Warp 进程而非全局 HID 队列（**这一层才是真正让按钮工作的那根线**；CGEvent 全局 tap 在用户机器上返回 true 却无效）
- 次选全局 `.cghidEventTap`（PID 未知时）
- 末选 `NSAppleScript` via System Events

### Phase 3 — 用户引导

- `AccessibilityPermissionManager.surfaceForWarpJumpIfNeeded` 在按钮未授权首次触发时拉起系统权限 alert
- 避免重复打扰：同一进程生命周期内只触发一次（`hasSurfacedWarpJumpPrompt` 开关）

## 风险与限制

1. **CGEvent 静默失败无法从代码内侧感知**：只能靠后效（用户观察 tab 是否切了）。这是 macOS AX API 的固有限制，无法在 Claude Island 内部解决。**减缓方案**：首选 `CGEventPostToPid` 直投目标进程，规避非激活 panel + 全局 HID 队列的静默丢弃交互——这是实测中真正让按钮工作的改动。
2. **Shift+Cmd+G 被用户改绑**：我们检测不到 Warp 的快捷键配置。现实中这个情况罕见，默认不处理，文档记录。
3. **NSAppleScript 要求「辅助功能」中的 System Events 授权**：与 Accessibility 是同一套权限体系，通常一起授予。若用户只授权了 Claude Island 未授权 System Events，AppleScript 分支也会失败——但这不是退化，CGEvent 一样要权限。
4. **`waitForFrontmost` 500ms 阈值**：太短误判率高，太长用户感知延迟。500ms 是观察得出的 P95 上限；如果有用户机器慢需调大，再通过遥测调整。

## 验证

手动回归：

1. 撤销 Claude Island 的 Accessibility 授权 → 点击跳转按钮
   - **期望**：Warp 被激活；Island 弹出权限引导；日志出现 `AX not trusted` warning
2. 恢复授权，杀掉 Warp 前的 claude session → hook 未跑过 → 点击跳转
   - **期望**：日志 `Warp detected but no TTY` warning；回退到通用 activate
3. 正常场景：多 tab Warp + 多 Claude 会话，每个都产生过活动
   - **期望**：点 A 会话按钮切到 A tab；点 B 切到 B tab；无论当前哪个 tab 在前都能切换
4. 把 Warp 窗口最小化 → 点击跳转
   - **期望**：Warp 恢复 + 切到目标 tab（复用 `bringAppToFront` 的 deminiaturize 逻辑）
5. tmux detached session → 点击跳转
   - **期望**：日志说明 detached；回退到通用 activate（与现状一致）

## 与已有文档关系

| 文档 | 定位 |
|---|---|
| [`warp-tab-focus.md`](./warp-tab-focus.md) | 基础设施：hook TTY 解析、OSC 0 标题追踪、闪烁引导 |
| [`warp-cli-agent-notification.md`](./warp-cli-agent-notification.md) | 引入 OSC 777 CLI Agent 协议 + Shift+Cmd+G 合成，首次实现真 tab 切换 |
| [`warp-cli-agent-upstream-sync.md`](./warp-cli-agent-upstream-sync.md) | 跟进上游 `claude-code-warp` 的 hook 映射与降级逻辑 |
| **本文** | 填补 Phase 2 按钮路径的失败模式：AX 校验、frontmost 等待、AppleScript 备选、TTY 缺失诊断 |
