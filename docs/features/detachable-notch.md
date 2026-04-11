# Feature: Detachable Notch with Lock/Unlock & Magnetic Snap

## Problem

Notch 面板固定在屏幕顶部 notch 区域，无法移动。用户可能希望将面板拖出放在屏幕其他位置方便查看，同时保留随时吸附回 notch 的能力。

## Goal

面板支持锁定/解锁两种模式。解锁后可拖拽到任意位置；拖拽到 notch 附近松手时自动磁吸回 notch 并恢复原始样式。

## 状态模型

```
┌─────────────────────────────────────────────────┐
│                  WindowMode                     │
│                                                 │
│   .docked (锁定在 notch)                         │
│     │  点击解锁按钮                                │
│     ▼                                           │
│   .docked (解锁，仍在 notch，可拖拽)               │
│     │  开始拖拽                                   │
│     ▼                                           │
│   .detaching (拖拽中，实时跟随鼠标)                 │
│     │                                           │
│     ├─ 松手位置靠近 notch → .docked (磁吸回弹)     │
│     │                                           │
│     └─ 松手位置远离 notch → .detached (独立浮窗)   │
│           │                                     │
│           ├─ 拖拽靠近 notch 松手 → .docked         │
│           └─ 点击锁定按钮 → .docked                │
│                                                 │
└─────────────────────────────────────────────────┘
```

```swift
enum WindowMode: Sendable {
    case docked          // 停靠在 notch，标准行为
    case detaching       // 拖拽进行中
    case detached        // 独立浮窗，脱离 notch
}
```

## 交互设计

### 锁定/解锁切换

- Notch 面板打开时，右上角显示锁图标 (🔒/🔓)
- 点击切换锁定状态
- 默认锁定；解锁后 notch 面板标题栏区域变为可拖拽区域
- 快捷键：notch 打开状态下 `⌘D` 切换

### 拖拽行为

- 仅在解锁状态下，按住面板顶部拖拽区域可拖出
- 拖拽开始时：从大窗口的内容偏移模式切换到独立小窗口
- 拖拽中：窗口实时跟随鼠标，半透明反馈
- 松手时触发磁吸判定

### 磁吸规则

```
磁吸判定半径: 120pt (以 notch 中心为圆心)

松手时:
  if 窗口中心距 notch 中心 < 120pt:
    → spring 动画回弹到 notch 位置
    → 恢复 docked 模式
    → 销毁独立窗口，回到大窗口模式
  else:
    → 窗口停在当前位置
    → 进入 detached 模式
```

### 磁吸视觉引导

- 拖拽进入磁吸半径时，notch 区域显示高亮引导（半透明发光边框）
- 距离越近，引导越明显（opacity 随距离线性变化）

### 样式差异

| 属性 | docked | detached |
|------|--------|----------|
| 窗口类型 | 大透明窗口内的偏移内容 | 独立小窗口 |
| 阴影 | 无 | 有 (NSShadow) |
| 圆角 | 匹配 notch 形状 | 统一 16pt 圆角 |
| 窗口层级 | `.mainMenu + 3` | `.floating` |
| 点击穿透 | 有 (透明区域) | 无 (整个窗口可交互) |
| 标题栏 | 无 | 可拖拽顶部栏 |

## 架构方案

### 核心问题：全屏宽大窗口

当前 `NotchPanel` 是全屏宽 × 750pt 高的透明窗口，实际内容只占中间一小块。这是为了复用 hit-test 穿透机制。拖出时不能直接移动这个大窗口。

### 方案：双窗口架构

```
docked 模式:
  NotchPanel (全屏宽大窗口，现有行为不变)
    └─ PassThroughHostingView
         └─ NotchView → 正常渲染

detached 模式:
  NotchPanel → 隐藏或仅保留 closed 状态的 notch 指示器
  DetachedPanel (新，独立小窗口)
    └─ NSHostingView
         └─ DetachedNotchView → 同样的内容，不同的容器样式
```

### 新增类型

```swift
// 独立浮窗 NSPanel
class DetachedPanel: NSPanel {
    // 有阴影、可拖拽、floating 层级
    // 标准窗口行为，无 hit-test 穿透
}

// 拖拽控制器
class NotchDragController {
    // 管理拖拽状态机
    // 监听 mouseDragged / mouseUp
    // 计算磁吸判定
    // 协调 NotchPanel ↔ DetachedPanel 切换
}
```

### 状态扩展

```swift
// NotchViewModel 新增
var windowMode: WindowMode = .docked
var isLocked: Bool = true             // 是否锁定在 notch
var dragOffset: CGPoint = .zero       // 拖拽偏移量

func toggleLock()
func beginDrag(at: NSPoint)
func updateDrag(to: NSPoint)
func endDrag(at: NSPoint) -> WindowMode  // 返回最终模式
```

### 事件流

```
用户点击解锁 → viewModel.toggleLock()
  → isLocked = false
  → 显示拖拽手柄

用户按住拖拽区域拖动 → NotchDragController.beginDrag()
  → windowMode = .detaching
  → 创建 DetachedPanel (内容快照或共享 viewModel)
  → 隐藏 NotchPanel 内的打开内容
  → DetachedPanel 跟随鼠标

鼠标移动 → NotchDragController.updateDrag()
  → DetachedPanel.setFrameOrigin(mouseLocation - offset)
  → 计算与 notch 距离，更新磁吸引导 UI

松开鼠标 → NotchDragController.endDrag()
  → 磁吸判定
  → 如果磁吸:
       spring 动画移向 notch 位置
       动画完成后销毁 DetachedPanel
       NotchPanel 恢复 opened 状态
       windowMode = .docked
  → 如果不磁吸:
       DetachedPanel 停在当前位置
       windowMode = .detached
```

## 需要修改的文件

| 文件 | 改动 |
|------|------|
| `Core/NotchViewModel.swift` | 新增 `windowMode`, `isLocked`, 拖拽相关状态和方法 |
| `UI/Window/NotchWindowController.swift` | 协调 NotchPanel 与 DetachedPanel 生命周期 |
| `App/WindowManager.swift` | 管理 DetachedPanel 的创建/销毁 |
| `UI/Views/NotchView.swift` | 显示锁图标、拖拽手柄、磁吸引导高亮 |
| `Events/EventMonitors.swift` | 可能需要新增 drag 专用流 (已有 drag 监听基础) |

## 新增文件

| 文件 | 职责 |
|------|------|
| `UI/Window/DetachedPanel.swift` | 独立浮窗 NSPanel 子类 |
| `UI/Views/DetachedNotchView.swift` | 脱离状态的 SwiftUI 容器视图 |
| `Core/NotchDragController.swift` | 拖拽状态机 + 磁吸判定逻辑 |

## 只读参考文件

| 文件 | 原因 |
|------|------|
| `UI/Window/NotchWindow.swift` | 理解 NotchPanel 配置，DetachedPanel 参考 |
| `UI/Window/NotchViewController.swift` | 理解 hit-test rect 计算，detached 模式不需要 |
| `Core/NotchGeometry.swift` | 磁吸判定需要 notch 屏幕坐标 |
| `Core/NSScreen+Notch.swift` | notch 尺寸和位置 |
| `Events/EventMonitor.swift` | 事件监听基础设施 |

## Edge Cases

- **面板关闭时拖拽**：仅 opened 状态允许拖拽，closed 状态忽略
- **detached 状态下 notch 仍需响应**：NotchPanel 保持 closed 状态的 dot 指示器，点击可打开（此时收回 DetachedPanel）
- **屏幕切换**：detached 窗口跨屏幕时限制在当前屏幕范围内
- **多显示器**：仅主屏（有 notch 的屏幕）支持磁吸回 notch
- **Chat 视图拖出**：detached 模式下 chat 滚动、键盘输入等需要正常工作
- **权限审批按钮**：detached 模式下 approve/deny 按钮需要正常工作
- **App 重启**：不持久化 detached 位置，重启后回到 docked 模式
- **窗口动画冲突**：拖拽中禁止 pop 动画和 hover 自动打开

## Out of Scope (Future)

- 持久化 detached 位置（记住上次拖出的位置）
- 多面板同时 detach（每个 session 独立窗口）
- 拖拽到屏幕边缘自动半屏吸附
- 画中画模式（缩小版只读面板）
- 手势支持（三指拖拽）
