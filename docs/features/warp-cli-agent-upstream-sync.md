# Feature Note: Warp CLI Agent 协议上游同步（2026-04）

跟进文档：`warp-cli-agent-notification.md`。本文记录从 `warpdotdev/claude-code-warp` 上游同步回来的变更、已修的问题，以及尚未回补的两处能力缺口。

## 背景

上游 `claude-code-warp` 自我们首次对齐（commit `57b8c4a`）以来已有 7 个语义变更（至 `0175f1f`，Apr 2026）。本次 review 发现：

- **payload 形状不变**：事件名与字段与我们的 `HOOK_EVENT_TO_CLI_AGENT` 映射仍完全兼容。
- **一处真 bug 在我们这边**：`PreToolUse → permission_request` 映射会在每次工具调用时弹 toast，与官方通过独立的 `PermissionRequest` hook 只在真正需要授权时触发的行为不符。已修。
- **两处降级逻辑落后上游**：SSH 场景与 broken Warp 版本屏蔽。未修，记录在此。

## 已修 — PreToolUse 误触发 permission_request

### 症状

Warp 在用户没有被问任何问题、没有权限请求的情况下频繁弹系统通知。每次 Bash / Grep / Read / Skill 工具调用都会弹一次。

### 根因

`claude-island-state.py:128` 的映射表把 `PreToolUse` 映射到 `permission_request`：

```python
HOOK_EVENT_TO_CLI_AGENT: dict[str, str] = {
    "PreToolUse": "permission_request",  # ← 错
    ...
}
```

Claude Code 的 `PreToolUse` hook **在每次工具调用前无条件触发**，无论工具是否真的需要用户授权。官方 `claude-code-warp/plugins/warp/hooks/hooks.json` 压根没注册 `PreToolUse`，它用的是 Claude Code 的**独立 `PermissionRequest` hook**（仅在需要用户确认时触发）。

### 修复

```python
HOOK_EVENT_TO_CLI_AGENT: dict[str, str] = {
    "SessionStart": "session_start",
    "UserPromptSubmit": "prompt_submit",
    "PostToolUse": "tool_complete",
    "PermissionRequest": "permission_request",  # ← 改为官方的专用 hook
    "Notification": "idle_prompt",
    "Stop": "stop",
}
```

`HookInstaller.swift:227` 已经在 `~/.claude/settings.json` 里注册了 `PermissionRequest`，`claude-island-state.py:816` 的 dispatch 分支也已经提取 `tool_name` / `tool_input` 到 `SessionState`——**只动映射表一行即可**。

### 教训

跟着官方 hooks.json 的 **hook event 名字逐字**映射，不要自作主张做语义近似。`PreToolUse ≠ PermissionRequest`，这和当初把 `Stop` 错映射为 `idle_prompt` 是同一类错误：下游协议被黑盒消费，任何"语义等价"替换都会被静默丢弃或误触发。

## 已修 — SSH 场景无通知

### 上游变更

commit `e4364ba`：从 `warp-notify.sh` 里移除 `TERM_PROGRAM=WarpTerminal` 硬门槛，改为仅凭 `WARP_CLI_AGENT_PROTOCOL_VERSION` 环境变量是否存在来判断。

**动机**：ssh 进 Warp 主机时 `TERM_PROGRAM` 往往被覆盖（远端 shell 设成 `xterm-256color` 或别的），但如果 Warp 把 `WARP_CLI_AGENT_PROTOCOL_VERSION` 透传进 ssh session（它会），plugin 仍然能工作。

### 我们的现状

`claude-island-state.py:177`：

```python
if os.environ.get("TERM_PROGRAM") != "WarpTerminal":
    return False
```

ssh 进其他机器跑 Claude Code 时，这条分支直接返回 False，完全不发 OSC 777。

### 修复

去掉 `TERM_PROGRAM` 判断，只保留 `WARP_CLI_AGENT_PROTOCOL_VERSION`：

```python
if not os.environ.get("WARP_CLI_AGENT_PROTOCOL_VERSION"):
    return False
```

官方 plugin 已经这样做并上线 SSH 场景；Warp 会把 `WARP_CLI_AGENT_PROTOCOL_VERSION` 透传进远端 shell，缺失即可判定为"不在可工作的 Warp 环境"。

## 已修 — broken Warp 版本误发

### 上游变更

commit `60de9e2`：新增 `WARP_CLIENT_VERSION` 环境变量检查，按 channel 做版本阈值比较。Warp 曾发布过一个 stable 版本，设了 `WARP_CLI_AGENT_PROTOCOL_VERSION` 但实际没开 `HOANotifications` feature flag——客户端声称支持结构化通知，但实际渲染不出来。

上游的黑名单阈值（`should-use-structured.sh`）：

```bash
LAST_BROKEN_DEV=""
LAST_BROKEN_STABLE="v0.2026.03.25.08.24.stable_05"
LAST_BROKEN_PREVIEW="v0.2026.03.25.08.24.preview_05"
```

### 我们的现状

`claude-island-state.py:186`：

```python
warp_version = os.environ.get("TERM_PROGRAM_VERSION", "")
if warp_version in WARP_BAD_VERSIONS:
    ...
```

两处不对：

1. **环境变量名错**：应为 `WARP_CLIENT_VERSION`，不是 `TERM_PROGRAM_VERSION`。
2. **黑名单策略错**：`WARP_BAD_VERSIONS` 是一个精确匹配的 `frozenset`（且当前为空），上游是按 channel 做**字符串阈值比较**（dev / stable / preview 三条独立阈值，`<=` 关系）。

结果：我们现在对 broken 版本毫无屏蔽。用户如果碰巧停留在受影响的 Warp 版本，我们会照发 OSC 777，Warp 静默丢弃——无害但无效。

### 修复

顶部常量（替代原 `WARP_BAD_VERSIONS` frozenset）：

```python
WARP_LAST_BROKEN_DEV = ""
WARP_LAST_BROKEN_STABLE = "v0.2026.03.25.08.24.stable_05"
WARP_LAST_BROKEN_PREVIEW = "v0.2026.03.25.08.24.preview_05"
```

`should_emit_warp_cli_agent()` 内：

```python
warp_client_version = os.environ.get("WARP_CLIENT_VERSION", "")
if not warp_client_version:
    return False

threshold = ""
if "dev" in warp_client_version:
    threshold = WARP_LAST_BROKEN_DEV
elif "stable" in warp_client_version:
    threshold = WARP_LAST_BROKEN_STABLE
elif "preview" in warp_client_version:
    threshold = WARP_LAST_BROKEN_PREVIEW
if threshold and warp_client_version <= threshold:
    return False
```

维护负担：上游如果再发现坏版本会更新 `should-use-structured.sh`，我们需要跟踪同步三个 `WARP_LAST_BROKEN_*` 常量。

## 其他上游变更（无需同步）

| 上游 commit | 变更 | 为什么不需要我们跟 |
|---|---|---|
| `f0ac3a1` | `PLUGIN_MAX_PROTOCOL_VERSION` → `PLUGIN_CURRENT_PROTOCOL_VERSION` | 纯重命名；我们的 `WARP_PROTOCOL_VERSION = 1` 已等价 |
| `55c1d9e` | `plugin.json` 改为 auto-discover hooks | 我们不是 Claude Code plugin，而是独立 app |
| `0175f1f` | 去掉 legacy on-session-start 的"not in Warp"横幅 | 我们不走 legacy 路径 |
| `22e45f6` | plugin.json 移除多余 strict field | 同上 |
| `82c06ad` / `6a07b80` | jq 缺失时的告警 emoji 调整 | 我们用 Python 不用 jq |

## 验证

改完后的期望行为（基于官方插件验证后的协议）：

| Claude Code hook | 是否弹 Warp 系统通知 | 前提 |
|---|---|---|
| `SessionStart` | 否 | 仅注册 agent |
| `UserPromptSubmit` | 否 | 仅更新 tab 状态点 |
| `PostToolUse` | 否 | 仅更新 tab 状态点 |
| `PreToolUse` | **否**（修复前：每次弹） | 我们不再映射 |
| `PermissionRequest` | 是 | 仅真正需要授权时触发 |
| `Notification` (idle_prompt) | 是 | Claude 暂停等输入 |
| `Stop` | 是 | 一个 turn 结束 |

回归验证步骤：

1. `cp ClaudeIsland/Resources/claude-island-state.py ~/.claude/hooks/claude-island-state.py`（或 rebuild app）
2. 新开 Claude Code 会话，跑多个自动批准的 Bash / Grep / Read 工具
3. 观察：Warp 在这些工具执行期间**不应**弹通知
4. 触发一个需要授权的工具（如未允许过的写文件），观察通知正常弹出
5. 让 Claude idle（空 prompt），观察 `idle_prompt` toast
6. 让 Claude 完成一个 turn，观察 `stop` toast

## 文件变更

| 文件 | 行 | 变更 |
|---|---|---|
| `ClaudeIsland/Resources/claude-island-state.py` | 128–138 | 映射表 `PreToolUse` → `PermissionRequest` |
| `ClaudeIsland/Resources/claude-island-state.py` | 140–148 | 替换 `WARP_BAD_VERSIONS` frozenset 为三个 `WARP_LAST_BROKEN_*` channel 常量 |
| `ClaudeIsland/Resources/claude-island-state.py` | 173–215 | `should_emit_warp_cli_agent()` 去掉 `TERM_PROGRAM` 门槛、加 `WARP_CLIENT_VERSION` + channel threshold 校验 |

未变更：`HookInstaller.swift`（`PermissionRequest` 已注册）、`HookConfigWriter.swift`、所有 Swift UI。

## 后续

- 定期 diff 上游 `should-use-structured.sh`，同步 `WARP_LAST_BROKEN_*` 常量。

上游仓库位置（供定期 diff）：`/Users/apple/Desktop/work/claude-code-warp`（`main` branch）。参考文件：
- `plugins/warp/hooks/hooks.json`（event → script 映射权威源）
- `plugins/warp/scripts/should-use-structured.sh`（降级判定权威源）
- `plugins/warp/scripts/build-payload.sh`（payload schema 权威源）
