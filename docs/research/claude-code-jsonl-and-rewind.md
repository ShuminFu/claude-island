# Claude Code JSONL 会话记录与 /rewind 机制分析

> 基于对 `~/.claude/projects/{projectDir}/{sessionID}.jsonl` 文件的实际数据分析。
> 分析样本：session `19eb46ca`，包含 541 条 JSONL 记录，经历了 3 次 /rewind 操作。

## 1. JSONL 文件概述

### 文件路径

```
~/.claude/projects/{projectDir}/{sessionID}.jsonl
```

其中 `projectDir` = 工作目录路径中 `/` 和 `.` 替换为 `-`。

例：cwd `/Users/apple/Desktop/work/claude-island` 对应目录 `-Users-apple-Desktop-work-claude-island`。

### 写入方式

**只追加（append-only）**。文件在整个会话生命周期内只增长，永远不会被截断或缩小。/rewind、/clear、中断等操作都不会删除已有内容，而是追加新的记录。

## 2. 消息类型（type 字段）

| type | 数量 | 说明 |
|------|------|------|
| `assistant` | 293 | Claude 的回复（文本、tool_use、thinking） |
| `user` | 214 | 用户消息、tool_result、中断标记 |
| `file-history-snapshot` | 16 | 文件版本快照（/rewind 的关键机制） |
| `system` | 7 | 系统消息（会话边界标记） |
| `queue-operation` | 6 | 消息队列操作（enqueue/dequeue） |
| `attachment` | 1 | 附件 |
| `custom-title` | 1 | 自定义会话标题 |
| `agent-name` | 1 | Agent 名称 |

## 3. 会话树结构（Conversation Tree）

### 核心字段

每条 JSONL 记录包含以下用于构建会话树的字段：

| 字段 | 说明 |
|------|------|
| `uuid` | 消息唯一标识 |
| `parentUuid` | 父消息 UUID，形成链式树结构 |
| `isSidechain` | 布尔值，标记是否为侧链（实际观察中全部为 `false`） |
| `promptId` | 同一次用户输入的所有消息共享同一 promptId |
| `messageId` | 用于 file-history-snapshot，与对应 user 消息的 uuid 相同 |

### 树的构建规则

```
消息 A (uuid=aaa, parentUuid=null)     ← 根节点
  └── 消息 B (uuid=bbb, parentUuid=aaa)
        └── 消息 C (uuid=ccc, parentUuid=bbb)
              ├── 消息 D (uuid=ddd, parentUuid=ccc)   ← 分支 1
              └── 消息 E (uuid=eee, parentUuid=ccc)   ← 分支 2（/rewind 创建）
```

**活跃链（Active Chain）**：从最新消息沿 `parentUuid` 链回溯到根节点所经过的所有消息。不在此链上的消息属于被放弃的分支。

### 会话开头结构

```jsonl
L0: file-history-snapshot  (初始快照)
L1: user                   (local-command /clear，parentUuid=null)
L2: user                   (/clear 命令内容，parentUuid=L1)
L3: system                 (系统边界消息，parentUuid=L2)
L4: file-history-snapshot  (用户首条消息前的快照)
L5: user                   (用户首条实际消息，parentUuid=L3)
L6: assistant              (Claude 回复，parentUuid=L5)
...
```

## 4. /rewind 机制详解

### /rewind 不截断文件

**关键发现**：`/rewind` 完全不修改或截断 JSONL 文件。相反，它：

1. 在 JSONL 文件末尾追加一条 `file-history-snapshot` 记录
2. 在其后追加新的用户消息，其 `parentUuid` 指向选定的回退检查点

### 完整示例（第一次 /rewind）

**回退前的会话链：**

```
L228: system     uuid=f809a174  ← 检查点（用户选择回退到这里）
L229: user "hi"  uuid=b6656519  parentUuid=f809a174
L231: assistant   回复           parentUuid=b6656519
L232: system                    parentUuid=L231
L234: user "hi"  uuid=3d9add57  parentUuid=L232
L235: assistant   回复           parentUuid=3d9add57
L236: system                    parentUuid=L235
```

**用户执行 /rewind，回退到 L228 处：**

```
L237: file-history-snapshot  messageId=94cb630e  ← 新增：快照记录
L238: user "rewind了..."     uuid=94cb630e  parentUuid=f809a174  ← 新增：指向 L228！
```

**结果**：L238 的 `parentUuid` 直接指向 L228（检查点），跳过了 L229-L236。这创建了一个**分叉（fork）**：

```
L228 (system, 检查点)
  ├── L229 → L231 → L232 → L234 → L235 → L236  ← 旧分支（被放弃）
  └── L238 → L239 → ...                          ← 新分支（活跃链）
```

### 时序图

```
时间线 (JSONL 追加顺序)
─────────────────────────────────────────────────>

L228    L229    L231    L234    L235    /rewind    L237    L238
 sys     hi     reply    hi    reply   (用户操作)  snap    new msg
  |       |       |       |      |                  |       |
  |       +-------+-------+------+ (旧分支)         |       |
  |                                                 |       |
  +-------------------------------------------------+-------+ (新分支: parentUuid→L228)
```

### 如何判断活跃分支（多 child 问题）

/rewind 后检查点有多个 child，旧记录的 `parentUuid` 不会被修改（只追加文件不能改历史）。判断方式是**从尾部反向回溯**：

```
L228 (检查点, 2 个 children)
  ├── L229 "hi" → L231 → ... → L236  (旧分支)
  └── L238 "rewind了" → L239 → ... → L540  (新分支)
```

从 **L540（文件最后一条消息）** 沿 `parentUuid` 向上走：

```
L540 → ... → L238 → L228 → ... → 根节点
```

经过的所有 uuid 构成 **active chain 集合**。L229-L236 不在链上，自然被排除。

**不需要从 parent 向下遍历 children，不需要对比 children 的时间戳或位置。** 只需一次从尾到根的线性回溯（O(n)），即可准确得到活跃分支。

### 多次 /rewind 的情况

同一个检查点可以被 /rewind 多次，每次创建新的分支：

```
L228 (检查点, 3 个 children)
  ├── L229 → ... → L236   (第一次对话，被放弃)
  ├── L238 → ... → L330   (第二次对话，被放弃)
  └── L500 → ... → L540   (第三次对话，当前活跃)
```

从 L540 回溯只经过 L500 → L228，前两个分支都被排除。每次 /rewind 都能正确处理，无论历史上 rewind 了多少次。

## 5. file-history-snapshot 详解

### 两种类型

| isSnapshotUpdate | 含义 | 出现时机 |
|------------------|------|----------|
| `false` | 全新快照 | 每次用户发送消息前、/rewind 后 |
| `true` | 增量更新 | 文件被修改后，更新已有快照中的文件备份 |

### 结构

```json
{
  "type": "file-history-snapshot",
  "messageId": "uuid-matching-next-user-message",
  "isSnapshotUpdate": false,
  "snapshot": {
    "messageId": "...",
    "timestamp": "2026-04-06T05:15:33.940Z",
    "trackedFileBackups": {
      "/path/to/file.swift": {
        "backupFileName": "hash@v3",
        "version": 3,
        "backupTime": "..."
      }
    }
  }
}
```

### messageId 与 user 消息的关系

snapshot 的 `messageId` 总是等于紧跟其后的 user 消息的 `uuid`。这建立了"快照 ↔ 消息"的一一对应关系，使得 /rewind 能够将文件状态恢复到该消息发送时的版本。

### 文件备份存储

备份文件存储在 `~/.claude/file-history/{sessionID}/` 目录下：

```
~/.claude/file-history/19eb46ca-.../
  1ab2d658ec167654@v1    (41KB, 第一个版本)
  1ab2d658ec167654@v2    (45KB, 第二个版本)
  1ab2d658ec167654@v3    (43KB, 第三个版本)
  6ca44fe9c95750fc@v2    (7KB)
  ...
```

文件名格式：`{pathHash}@v{version}`。内容是对应代码文件在该版本时的完整快照。/rewind 时会根据目标检查点的 `trackedFileBackups` 恢复这些文件。

## 6. 并行 Tool 执行的分叉

除了 /rewind，JSONL 中还有另一种分叉：**并行 tool_use**。

当 Claude 在一次回复中同时调用多个工具时：

```
L14: assistant  tool_use(A)  uuid=aaa
L15: assistant  tool_use(B)  uuid=bbb  parentUuid=aaa  (链式追加)
L16: assistant  tool_use(C)  uuid=ccc  parentUuid=bbb  (链式追加)
L17: user       tool_result(B)         parentUuid=bbb  ← B 的结果
L18: user       tool_result(A)         parentUuid=aaa  ← A 的结果
L19: user       tool_result(C)         parentUuid=ccc  ← C 的结果
```

工具调用是链式发出的（B 的 parent 是 A），但结果可能以不同顺序返回，导致同一个 parent 有多个 children。这不是 /rewind，而是并行执行的正常结构。

**区分方式**：/rewind 分叉的特征是 `file-history-snapshot` 出现在分叉点附近，且新分支跳过了多个中间消息。并行 tool 分叉的特征是同一 parent 下既有 assistant（后续 tool_use）又有 user（tool_result）。

## 7. 其他特殊消息类型

### system 消息

空内容的系统消息作为会话中的**边界标记**。每轮对话结束后（assistant 回复后）会插入一条 system 消息，为下一轮对话提供挂载点。

```
L226: assistant  "All done. Here's a summary..."
L227: system     (空内容，parentUuid=L226)
L228: system     (空内容，parentUuid=L227)   ← /rewind 检查点通常在这里
L229: user       "hi"  (parentUuid=L228)
```

### queue-operation

用于消息队列管理（enqueue/dequeue），无 uuid/parentUuid，不参与会话树。

## 8. 对 Claude Island 的影响

### 当前问题

ConversationParser 将所有 `user`/`assistant` 消息线性追加到 `messages` 数组，不考虑 parentUuid 树结构。/rewind 后旧分支消息仍然显示。

### 解决方案

在 ConversationParser 中跟踪每条消息的 `parentUuid`，构建 `parentMap: [String: String]`（uuid → parentUuid 映射）。解析完成后从最新消息沿 parentUuid 回溯，得到活跃链上的所有 uuid 集合，过滤掉不在活跃链上的消息。

### 注意事项

1. **并行 tool_use 不能被过滤**：同一 parent 的多个 children 中，tool_result 不在主链上但仍是活跃对话的一部分。活跃链回溯会自然包含正确的分支。
2. **file-history-snapshot 无 parentUuid**：快照记录不参与树结构，解析时直接跳过。
3. **isSidechain 字段不可靠**：实际观察中所有消息的 `isSidechain` 都是 `false`，不能用于判断活跃分支。

## 9. 相关文件路径

| 路径 | 说明 |
|------|------|
| `~/.claude/projects/{projectDir}/{sessionID}.jsonl` | 会话 JSONL 日志（只追加） |
| `~/.claude/file-history/{sessionID}/{hash}@v{n}` | 文件版本备份 |
| `~/.claude/history.jsonl` | 全局命令历史（记录 /rewind 等命令） |
| `~/.claude/backups/.claude.json.backup.*` | 配置文件备份 |
