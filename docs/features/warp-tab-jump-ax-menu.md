# Feature: Warp Tab Jump via AX "Switch to Next Tab" Menu Walk

跟进文档：[`warp-tab-jump-hardening.md`](./warp-tab-jump-hardening.md)、[`warp-cli-agent-notification.md`](./warp-cli-agent-notification.md)。

## 背景

Hardening 文档里描述的 OSC 777 `idle_prompt` + `Shift+Cmd+G` 方案在实测中仍然不工作——面板「跳转终端」按钮只能激活 Warp 或跳到错误的 tab。本文记录排查过程、根因、以及最终换用的 AX 菜单方案。

## 症状

点击面板上的跳转按钮，日志四步全绿：

```
jumpToWarpTab: tty=/dev/ttys001, session=8b5dc42c-...
emitWarpCLIAgentIdle: wrote 265 bytes to /dev/ttys001
jumpToWarpTab: OSC emit ok, activating Warp
jumpToWarpTab: waitForFrontmost=true pid=650
postKeystroke: delivered Shift+Cmd+G to pid 650
jumpToWarpTab: sendJumpToLatestToast=true
```

Warp 被激活——但停在上次的 tab，或者跳到「最近活跃过」的某个非目标 tab。

## 排查过程

### 步骤 1：确认 payload 对齐上游

对比 `claude-code-warp/plugins/warp/scripts/build-payload.sh`，发现我们的 OSC payload 缺 `cwd` 字段。补齐后 payload 字节数从 207 → 265，但症状不变：仍然跳到错误 tab。

### 步骤 2：验证 OSC 是否真的抵达 Warp

把 `summary` 字段改成带时间戳的唯一字符串 `Claude Island jump diag <unix-ts>`，让用户点击后去 Warp 的通知中心/toast 区看是否出现。

**结果：外部写入的 OSC 在 Warp 里看不到任何 toast；但 Claude Code 内部的 Python hook 发出的 OSC 仍然正常弹 toast。**

这一步把根因锁死在「外部进程写 pty slave 与 pty 内部进程写 pty slave，Warp 的处理不同」。

### 步骤 3：分析为什么外部写入被丢弃

- Python hook 是 Claude Code 的子进程，运行在 Warp tab 的 pty slave 里，写 stdout/`/dev/ttysNNN` 时，字节通过 pty 的正常输出路径流向 master，Warp 读到后能解析 OSC 777。
- Claude Island 是独立 GUI 进程，不在任何 pty 的 session 里。虽然 `open("/dev/ttysNNN", "w")` 在 syscall 层能成功，内核甚至报告「写入 265 字节」——但 **Warp 看来只处理那些「被 pty 主进程组当作输出」的字节**。外部进程开 slave 后写入的字节，Warp 的 CLI Agent 协议解析器不认。

换句话说：pty slave 的 write 在 kernel 层一视同仁，但 Warp 在 user space 做了额外的来源校验/过滤。我们没法从外部进程伪造「pty 内部输出」，除非 fork 到 pty session 里——代价太大。

### 步骤 4：放弃 OSC 路径，转向 AX

只要能拿到「Warp 当前选中哪个 tab」的可观测信号，就能反向控制。dump Warp 的 AX tree：

```
AXWindow count = 1       ← 所有 tab 共用一个 NSWindow
  AXWindow.title = "⏸ Claude: <project>"  ← 反映当前选中 tab
  子树几乎为空            ← tab bar 和终端是 GPU 渲染，不暴露给 AX
```

结论：**AXWindow.title 是唯一的观测信号**，但 **tab bar 没法直接 AXPress**。

幸运的是 Warp 菜单栏的 `Tab > Switch to Next Tab` 是标准 AXMenuItem，可以直接 `AXUIElementPerformAction(kAXPressAction)` 调用。

### 步骤 5：验证 AX 菜单步进

一个独立的 Swift 脚本循环调用 `Switch to Next Tab`，每次读 `AXWindow.title`：

```
start: ⠐ Investigate prompt none handling
step 1: ⏸ Claude: work
step 2: ⠂ Fix Warp terminal jump to target tab
step 3: ⏸ Claude: src
step 4: ⏸ Claude: dintalclaw-masters
...
step 8: ⠂ Investigate prompt none handling   ← 循环回起点
```

- tab 切换触发 title 同步更新，无需额外延迟。
- 8 个 tab 在 ~640ms 内完成一圈（每步 80ms，sleep 占主）。
- 循环检测：step > 1 时 title 回到 start → 没有匹配的 tab。

## 方案

`TerminalFocuser+Warp.swift` 重写后的流程：

```
用户点击跳转
  → TerminalFocuser.focus(session:)
  → jumpToWarpTab(projectName: session.projectName)
       1. AXIsProcessTrusted() 前置校验
            失败 → AccessibilityPermissionManager.surfaceForWarpJumpIfNeeded
                   激活 Warp（不切 tab）→ return false
       2. NSRunningApplication.activate(Warp)
       3. waitForFrontmost(warpBundleIDs, timeout: 500ms)
       4. AX 读 AXFocusedWindow.title → 若已包含 projectName，直接返回
       5. AX 定位菜单项 Tab > Switch to Next Tab
       6. 循环 20 步：
            AXUIElementPerformAction(nextTabItem, kAXPressAction)
            sleep 25ms
            读 AXWindow.title
              ├─ 含 projectName → return true
              ├─ step > 1 且 title 回到 startTitle → return false（未匹配）
              └─ 继续下一步
       7. 超过 20 步仍未匹配 → 记日志 return false
```

### 匹配规则

`titleMatches(windowTitle, project)` = `windowTitle.localizedCaseInsensitiveContains(project)`。

Warp 的 tab 标题模板：
- idle：`"⏸ Claude: <basename(cwd)>"` → 直接命中 project
- 任务执行中：`"✳ <prompt-derived-text>"` → 从 prompt 派生，可能不含 project → miss（可接受的降级）

未来若 Warp 更新标题模板把 session 信息暴露出来，可以加更精确的匹配。

## 已知限制

1. **同 project 多 session 无法区分**：两个在 `dintalclaw-masters` 的 Claude 会话，标题完全一致（`"⏸ Claude: dintalclaw-masters"`），命中第一个就停。只要落在正确的 project 就算达标——这是 Warp 标题信息量的限制，不是代码问题。
2. **任务执行中的标题以 prompt 命名**：此时 `titleMatches` 不命中，循环会走完 20 步然后放弃。用户感知：Warp 在前台但 tab 没切。改进方向是 Warp 官方给 tab 暴露 session_id 或 cwd 字段。
3. **20 步上限**：覆盖 95% 用户。>20 tab 的用户仍然可以手动切。
4. **切换过程会依次经过中间 tab**：每步 25ms，10 个 tab = 250ms，肉眼可感但不算打断。AX `AXPress` 目前是最便宜的切法，Cmd+1..9 快不了多少且不支持 >9。

## 为什么不走其他路径

| 候选 | 否决原因 |
|---|---|
| 修 OSC 777 路径 | Warp 只认 pty 内部进程写入的字节，外部没法伪装；详见步骤 3 |
| AX 直接 AXPress tab 按钮 | Warp 的 tab bar 是 GPU 渲染，AX tree 里不存在 tab 元素 |
| Cmd+1..9 | 需要知道 tab index（AX 同样拿不到），且 >9 失效 |
| Cmd+P 命令面板 → 输入 project → Enter | 会弹 palette UI，闪烁；且命中 project 后若有多个还得二次选择 |
| warp:// URL scheme | 目前只有 `warp://cli-agent`，没有「focus tab by session」的公开 URL |
| 读 Warp 内部数据库强制切 tab | 只读状态，改不了 UI 选中 |
| fork 到目标 pty 里再 write OSC | 代价过大，且 setsid 跨进程控制终端有安全限制 |

## 文件变更

| 文件 | 变更 |
|---|---|
| `ClaudeIsland/Services/Window/TerminalFocuser+Warp.swift` | 完全重写：删除 OSC emit + Shift+Cmd+G，改为 AX 菜单步进；保留 AX 权限门、`waitForFrontmost`、Warp 变体识别 |
| `ClaudeIsland/Services/Window/TerminalFocuser.swift` | 签名同步：`jumpToWarpTab(cwd:)` 新参（保留以维持 API，内部未使用） |

未改：Python hook（`claude-island-state.py` 里的 `emit_warp_cli_agent_event` 仍然是 Warp 接收 toast 的主路径——它有效，动它反而打破现有通知功能）。

## 验证清单

手动回归：

1. **单一 project，多 tab**：A/B/C 三个 tab 分属不同 project。从 A 点 B 的跳转按钮 → 落在 B。从 C 点 A → 落在 A。
2. **已经在目标 tab**：点自己的跳转按钮 → 日志 `already on target tab`，不动。
3. **Warp 最小化状态**：点跳转 → Warp 恢复并切到目标 tab。
4. **同 project 双 session**：两个 tab 都是 `dintalclaw-masters` → 命中循环中第一个，落在正确 project，用户可见（有可能不是原意的那个 session）。
5. **任务执行中**（标题变成 prompt 派生）：循环走完 20 步不命中 → Warp 激活但 tab 未切。日志 `gave up after 20 steps`。
6. **撤销 AX 授权**：点跳转 → `AX not trusted` warning，激活 Warp 不切 tab，Island 弹权限引导。
7. **tmux detached session**：上游分支判断无 TTY → 走通用 activate 路径，与本改动无关。

## 经验教训

1. **TTY write 成功 ≠ 对端能解析**。kernel 层的 `write()` 返回字节数只说明 pty 收下了 bytes；user-space 的终端模拟器完全可以基于写入进程身份做额外过滤。排查必须在对端（Warp 看到了什么）做验证，单边 log 不够。
2. **独特 marker 是最便宜的跨进程可观测手段**。把 `summary` 改成带时间戳的唯一串、让用户肉眼在另一侧观察，一次问答就锁定了根因——比翻 20 行日志快得多。
3. **GPU 渲染的 app 通常不暴露内部 UI 给 AX**，但菜单栏是 AppKit 标准组件、几乎都会暴露。菜单栏 + AXWindow.title 经常是唯一的自动化突破口。
4. **Root-cause 明确后敢于丢掉死代码**。OSC + Shift+Cmd+G 路径在这个问题里零作用，保留它只增加阅读负担。文档里标清楚为什么删即可，无需为「未来 Warp 可能修」预留。
