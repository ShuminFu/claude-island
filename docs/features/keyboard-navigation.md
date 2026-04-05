# Feature: Keyboard Navigation for Notch Panel

## Problem

After opening the notch panel via the global hotkey (`⌥C`), users must switch to the mouse to browse sessions, enter chat, or go back. This breaks the keyboard-driven workflow.

## Goal

Full keyboard navigation within the notch panel so users never need to touch the mouse after pressing the hotkey.

## Navigation Map

```
NOTCH OPENS (via ⌥C)
  → Instances List (session cards)
      ↑/↓     Select session
      Enter    Open selected session's chat
      ←        Go to menu
      Escape   Close notch

  → Chat View
      Escape   Back to instances list
      Tab      Focus message input (if tmux available)

  → Menu
      ↑/↓     Navigate menu items
      Enter    Activate item / toggle setting
      →/Esc    Back to instances list
```

## Behavior Details

### Instances List

- On open, first session is auto-selected (highlighted)
- `↑`/`↓` moves selection. Wraps around at boundaries
- Selected session has a visible focus ring or highlight (subtle border or background change matching the terminal aesthetic)
- `Enter` on a session opens its chat view (`viewModel.showChat(for:)`)
- `Enter` on a session in `waitingForApproval` could trigger approve (stretch goal)
- `Escape` closes the notch (`viewModel.notchClose()`)
- `←` switches to menu (`viewModel.toggleMenu()`)

### Chat View

- `Escape` returns to instances list (`viewModel.exitChat()`)
- `Tab` focuses the message input field (when tmux messaging is available)
- Arrow keys should NOT interfere with message input when text field is focused

### Menu

- `↑`/`↓` moves selection through menu items
- `Enter` activates the selected item (toggle, open sub-view, etc.)
- `→` or `Escape` returns to instances list

## Implementation Approach

### Focus State Management

Add a `@State private var selectedIndex: Int?` to `ClaudeInstancesView` and `NotchMenuView`. Track which item is focused.

### Key Event Handling

Add a `keyDown` `EventMonitor` (local only) in `NotchView` that is active only when the notch is `.opened`. Route key events based on current `contentType`:

- `.instances` → `ClaudeInstancesView` keyboard handler
- `.menu` → `NotchMenuView` keyboard handler  
- `.chat` → Only handle `Escape` (let text field handle other keys)

### Visual Feedback

Selected session card gets a highlight style:
- Light border (`Color.white.opacity(0.15)`) or background tint
- Matches existing hover style used by `InstanceRow.isHovered`

### Key Files to Modify

| File | Change |
|------|--------|
| `ClaudeIsland/UI/Views/NotchView.swift` | Add local key event monitor when opened |
| `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` | Add `selectedIndex`, highlight style, Enter/arrow handling |
| `ClaudeIsland/UI/Views/NotchMenuView.swift` | Add `selectedIndex`, arrow/Enter handling for menu items |
| `ClaudeIsland/UI/Views/ChatView.swift` | Handle Escape to exit chat |
| `ClaudeIsland/Core/NotchViewModel.swift` | Possibly add `handleKeyEvent()` router method |

### Key Files (Read-Only Reference)

| File | Why |
|------|-----|
| `ClaudeIsland/Events/EventMonitor.swift` | Reuse for local key monitoring |
| `ClaudeIsland/Models/SessionState.swift` | Session data for selection |
| `ClaudeIsland/Core/GlobalHotkeyManager.swift` | Avoid conflicts with global hotkey |

## Edge Cases

- Empty session list: arrow keys are no-ops, Enter is no-op
- Session list changes while navigating: clamp `selectedIndex` to valid range
- Global hotkey pressed while panel is open: should close (already handled by `toggleNotch`)
- Text field focused in chat: arrow keys should go to text field, not navigation
- Recording hotkey in settings: key events should not trigger navigation

## Out of Scope (Future)

- Vim-style `j`/`k` navigation
- Number keys to jump to session N
- `a`/`d` to approve/deny directly from instances list
- Search/filter sessions by typing
