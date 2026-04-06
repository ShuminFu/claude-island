<div align="center">
  <img src="docs/logo.svg" alt="Logo" width="256" height="256">
  <p>
    <a href="https://github.com/ShuminFu/claude-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/ShuminFu/claude-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/ShuminFu/claude-island/total?style=rounded&color=white&labelColor=000000">
    </a>
    <a href="https://opensource.org/licenses/Apache-2.0" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg?style=rounded&labelColor=000000" alt="License: Apache 2.0">
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/Swift-6-F05138.svg?style=rounded&labelColor=000000" alt="Swift 6">
    </a>
    <a href="https://deepwiki.com/ShuminFu/claude-island">
      <img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki">
    </a>
  </p>
  <h3 align="center">Claude Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
  </p>
</div>

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Hooks install automatically on first launch

## About This Fork

This is a fork of [claude-island](https://github.com/engels74/claude-island) by engels74 (originally from [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island)).

Key improvements in this fork:

- **Chat history** — Full conversation history with markdown rendering, auto-load on app restart
- **Smart session list** — Intelligent summaries, system message filtering, unread markers on hover/select
- **Keyboard navigation** — Shortcut hints on approval buttons, keyboard scrolling in session details, quick approve/deny via hotkeys
- **Terminal integration** — Tab flash prompts for all terminal jump entries, Git info display
- **Bug fixes** — Fixed overlay window intercepting mouse events, panel mouse trapping, `/clear` blank session, and more

## Requirements

- macOS 15.6+
- Claude Code CLI
- **Python 3.14+** or **[uv](https://docs.astral.sh/uv/)** — the hook script requires one of these to run

### Installing Python 3.14

The app will prompt you on first launch if no suitable runtime is found. You can install ahead of time:

**Option A — uv (recommended, no Python install needed):**

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
# Installs to ~/.local/bin/uv
```

**Option B — Homebrew:**

```bash
brew install python@3.14
# Installs to /opt/homebrew/bin/python3.14 (Apple Silicon)
# or /usr/local/bin/python3.14 (Intel)
```

**Option C — pyenv:**

```bash
pyenv install 3.14
# Installs to ~/.pyenv/versions/3.14.x/bin/python3
```

**Option D — Official installer:**

Download from [python.org/downloads](https://www.python.org/downloads/).

> **Note:** macOS ships with Python 3, but it is typically too old. The hook script (`~/.claude/hooks/claude-island-state.py`) requires Python 3.14+ features.

> **How it works:** On first launch, Claude Island detects the runtime once and writes the **absolute path** into `~/.claude/settings.json` (e.g. `/opt/homebrew/bin/uv run ~/.claude/hooks/claude-island-state.py` or `/opt/homebrew/bin/python3.14 ~/.claude/hooks/claude-island-state.py`). The app searches in this order: uv → versioned python3.14 (Homebrew) → pyenv 3.14.x → generic python3 (if ≥ 3.14). If you later change your Python installation, relaunch the app to re-detect.

## Installation Guide

### Step 1 — Install the App

Download the latest `.dmg` from [GitHub Releases](https://github.com/ShuminFu/claude-island/releases/latest), open it, and drag **Claude Island** into **Applications**. [`IMG`](docs/screenshots/cropped/001.png)

### Step 2 — Bypass Gatekeeper

Claude Island is ad-hoc signed and not notarized, so macOS blocks the first launch.

1. Open the app — macOS shows **"Claude Island" Not Opened**. Click **Done**. [`IMG`](docs/screenshots/cropped/002.png)
2. Go to **System Settings → Privacy & Security**, find the blocked notice, and click **Open Anyway**. [`IMG`](docs/screenshots/cropped/003.png)
3. In the confirmation dialog, click **Open Anyway**. [`IMG`](docs/screenshots/cropped/004.png)
4. Authenticate with Touch ID or your password. [`IMG`](docs/screenshots/cropped/005.png)

### Step 3 — Grant Keychain Access

macOS prompts for access to **"Claude Code-credentials"** (the CLI's OAuth token, used for optional usage-quota tracking). Click **Always Allow**. [`IMG`](docs/screenshots/cropped/006.png)

### Step 4 — Grant Accessibility Permission

1. The app shows an **Accessibility Permission Required** dialog. Click **Open Settings**. [`IMG`](docs/screenshots/cropped/007.png)
2. In **System Settings → Privacy & Security → Accessibility**, click the **+** button. [`IMG`](docs/screenshots/cropped/008.png)
3. Navigate to **Applications**, select **Claude Island**, and click **Open**. [`IMG`](docs/screenshots/cropped/009.png)
4. Claude Island now appears in the Accessibility list with the toggle enabled. [`IMG`](docs/screenshots/cropped/010.png)

> **Tip:** If Claude Island is already listed but not working, remove it first (click **−**), then re-add it with the steps above.

Subsequent launches require no extra setup. Auto-updates via Sparkle work normally.

**Permissions Questions?** See the upstream docs for [why Claude Island needs accessibility and keychain permissions](https://deepwiki.com/search/is-claude-island-safe-to-use-i_b6aed731-54db-4ac4-89e5-7ce9ad984006).

### Alternative: Terminal Bypass

If you prefer, you can skip the Gatekeeper steps above by removing the quarantine attribute:

```bash
xattr -d com.apple.quarantine "/Applications/Claude Island.app"
```

### Alternative: Build from Source

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

### Walkthrough

![Installation guide walkthrough](docs/screenshots/gif/installation-guide.gif)

## How It Works

Claude Island installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in the notch overlay.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons—no need to switch to the terminal.

## License

Apache 2.0
