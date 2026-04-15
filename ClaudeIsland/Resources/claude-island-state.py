#!/usr/bin/env python3
# /// script
# requires-python = ">=3.14"
# ///
"""Claude Island Hook - Session state bridge to ClaudeIsland.app.

Sends session state to ClaudeIsland.app via Unix socket.
For PermissionRequest events, waits for user decisions from the app.

Requires: Python 3.14+
"""

__all__ = [
    "HookEventData",
    "PermissionResponse",
    "SessionState",
    "SessionStateDict",
    "ToolExtras",
    "ToolInputType",
    "determine_status",
    "emit_warp_cli_agent_event",
    "get_claude_pid",
    "get_tty",
    "handle_permission_response",
    "is_hook_event_data",
    "is_permission_response",
    "is_session_active",
    "main",
    "send_event",
    "get_git_info",
    "get_terminal_tty",
    "should_emit_warp_cli_agent",
    "update_tab_title",
    "validate_tty",
]

import json
import os
import socket
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import NotRequired, TypedDict, TypeIs, cast


# TypedDict definitions for JSON structures
class HookEventData(TypedDict, total=False):
    """Input data from Claude Code hook via stdin."""

    session_id: str
    hook_event_name: str
    cwd: str
    tool_name: str
    tool_input: dict[str, str | int | bool | list[str] | None]
    tool_use_id: str
    notification_type: str
    message: str


class ToolExtras(TypedDict, total=False):
    """Extra fields returned by determine_status()."""

    tool: str
    tool_input: dict[str, str | int | bool | list[str] | None]
    tool_use_id: str
    notification_type: str
    message: str


class PermissionResponse(TypedDict, total=False):
    """Response from ClaudeIsland.app for permission requests."""

    decision: str
    reason: str


class SessionStateDict(TypedDict):
    """Dictionary representation of SessionState for JSON serialization."""

    session_id: str
    cwd: str
    event: str
    pid: int
    tty: str | None
    tty_valid: bool
    session_active: bool
    status: str
    terminal_tty: NotRequired[str | None]
    tool: NotRequired[str]
    tool_input: dict[str, str | int | bool | list[str] | None]  # Always included
    tool_use_id: NotRequired[str]
    notification_type: NotRequired[str]
    message: NotRequired[str]
    git_repo_name: NotRequired[str | None]
    git_branch: NotRequired[str | None]
    git_is_worktree: NotRequired[bool]


ToolInputType = dict[str, str | int | bool | list[str] | None]

SOCKET_PATH = Path("/tmp/claude-island.sock")
CONNECT_TIMEOUT_SECONDS = 5  # Fast-fail if app is unresponsive
PERMISSION_RECV_TIMEOUT_SECONDS = 300  # Must match Swift's permissionTimeoutSeconds

# --- Warp CLI Agent integration ---
#
# Reference: https://github.com/anthropics/claude-code/tree/main/plugins/warp
# Protocol: OSC 777 ; notify ; warp://cli-agent ; <json-body> BEL
# Warp's CLI Agent subsystem consumes these frames to render a tab status dot,
# post a native macOS notification, and mark the tab as "wakeable" so
# Shift+Cmd+G can jump to it.
WARP_CLI_AGENT_TITLE = "warp://cli-agent"
WARP_PROTOCOL_VERSION = 1

# Hook config file written by the Swift app (AppSettings → HookConfigWriter).
# Absent / unreadable file means: defaults (mode = "both", warp emit enabled).
HOOK_CONFIG_PATH = Path.home() / ".claude" / ".claude-island-hook-config.json"

# Status (from `determine_status`) → CLI Agent event name. Events not in this
# map are intentionally not forwarded to Warp (e.g. "notification", "skip",
# "unknown") — they have no useful Warp-side semantics.
STATUS_TO_CLI_AGENT_EVENT: dict[str, str] = {
    "processing": "user_prompt_submit",
    "running_tool": "post_tool_use",
    "waiting_for_input": "idle_prompt",
    "waiting_for_approval": "permission_request",
    "compacting": "user_prompt_submit",  # Visually keep "running"
    "ended": "stop",
}

# Phase 4: known-bad Warp versions where the CLI Agent path misbehaves.
# Add entries here to silently downgrade affected users to OSC 0 only.
# Match against TERM_PROGRAM_VERSION exactly. Remove once Warp ships a fix.
WARP_BAD_VERSIONS: frozenset[str] = frozenset()

# Stderr log prefix — Claude Code captures hook stderr, makes it greppable.
_LOG_PREFIX = "[claude-island/warp]"


def _log_warp(msg: str, /) -> None:
    """Best-effort stderr log for Warp CLI Agent path diagnostics."""
    try:
        print(f"{_LOG_PREFIX} {msg}", file=sys.stderr, flush=True)
    except OSError:
        pass


def _load_hook_config() -> dict[str, object]:
    """Load Swift-managed hook config (warp mode, etc).

    Returns an empty dict if the file is missing, unreadable, or invalid —
    callers must treat all keys as optional.
    """
    try:
        with open(HOOK_CONFIG_PATH, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(raw, dict):
        return {}
    return cast(dict[str, object], raw)


def should_emit_warp_cli_agent() -> bool:
    """Gate: only emit when running inside Warp with a known-good version
    AND the user has not opted out via Settings (mode != "island-only").
    """
    if os.environ.get("TERM_PROGRAM") != "WarpTerminal":
        return False

    # Protocol version is advertised by Warp itself — absence means too old.
    if not os.environ.get("WARP_CLI_AGENT_PROTOCOL_VERSION"):
        return False

    # Phase 4: skip known-bad Warp versions.
    warp_version = os.environ.get("TERM_PROGRAM_VERSION", "")
    if warp_version in WARP_BAD_VERSIONS:
        _log_warp(f"skip: blacklisted Warp version {warp_version!r}")
        return False

    # Swift-side toggle (Phase 3). Mode == "island-only" disables OSC 777.
    cfg = _load_hook_config()
    mode = cfg.get("warpCLIAgentMode")
    if mode == "island-only":
        return False
    enabled = cfg.get("warpCLIAgentEnabled")
    # `enabled` defaults to True; only an explicit `False` opts out.
    if enabled is False:
        return False

    return True


def _permission_summary(state: "SessionState", /) -> str:
    """Build a short, user-readable summary line for permission_request events.

    Mirrors the conventions used by claude-code-warp/build-payload.sh —
    "Run Bash: <cmd>", "Edit: <path>", etc.
    """
    tool = state.tool or "tool"
    tool_input = state.tool_input or {}

    if tool == "Bash":
        cmd = tool_input.get("command")
        if isinstance(cmd, str) and cmd:
            short = cmd if len(cmd) <= 80 else cmd[:77] + "..."
            return f"Run Bash: {short}"
    if tool in {"Edit", "Write", "Read", "NotebookEdit"}:
        path = tool_input.get("file_path") or tool_input.get("notebook_path")
        if isinstance(path, str) and path:
            return f"{tool}: {path}"
    if tool == "WebFetch":
        url = tool_input.get("url")
        if isinstance(url, str) and url:
            return f"WebFetch: {url}"

    return f"Use {tool}"


def emit_warp_cli_agent_event(
    state: "SessionState",
    terminal_tty: str | None,
    /,
) -> None:
    """Write an OSC 777 `warp://cli-agent` frame to the terminal TTY.

    Tab membership is determined by Warp from the pty master fd holding the
    terminal_tty — we do not need to (and cannot) name the tab in the payload.

    Silent on every failure path: a missing TTY, closed file descriptor, or
    permission error must not break the hook flow. Diagnostics go to stderr
    via `_log_warp` only when the path is genuinely interesting.
    """
    if not terminal_tty:
        return
    if not should_emit_warp_cli_agent():
        return

    cli_event = STATUS_TO_CLI_AGENT_EVENT.get(state.status)
    if not cli_event:
        return

    # Negotiate protocol version (min of plugin & Warp).
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

    # Per-event enrichment (mirrors build-payload.sh conventions).
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
    except OSError as exc:
        # Common cases: tty closed, /dev permission lost. Don't spam stderr —
        # these are routine when sessions tear down. Log once at debug-ish level.
        _log_warp(f"emit failed for {terminal_tty}: {exc.__class__.__name__}")


@dataclass(slots=True, frozen=True)
class SessionState:
    """Represents the state of a Claude Code session."""

    session_id: str
    cwd: str
    event: str
    pid: int
    tty: str | None
    tty_valid: bool = False
    session_active: bool = True
    status: str = "unknown"
    tool: str | None = None
    tool_input: ToolInputType = field(default_factory=dict)
    tool_use_id: str | None = None
    terminal_tty: str | None = None
    notification_type: str | None = None
    message: str | None = None
    git_repo_name: str | None = None
    git_branch: str | None = None
    git_is_worktree: bool = False

    def to_dict(self, /) -> SessionStateDict:
        """Convert to dictionary for JSON serialization."""
        result: SessionStateDict = {
            "session_id": self.session_id,
            "cwd": self.cwd,
            "event": self.event,
            "pid": self.pid,
            "tty": self.tty,
            "tty_valid": self.tty_valid,
            "session_active": self.session_active,
            "status": self.status,
            "tool_input": self.tool_input,  # Required field - include in literal
        }

        if self.terminal_tty is not None:
            result["terminal_tty"] = self.terminal_tty
        if self.tool is not None:
            result["tool"] = self.tool
        if self.tool_use_id is not None:
            result["tool_use_id"] = self.tool_use_id
        if self.notification_type is not None:
            result["notification_type"] = self.notification_type
        if self.message is not None:
            result["message"] = self.message
        if self.git_repo_name is not None:
            result["git_repo_name"] = self.git_repo_name
        if self.git_branch is not None:
            result["git_branch"] = self.git_branch
        if self.git_is_worktree:
            result["git_is_worktree"] = self.git_is_worktree

        return result


def validate_tty(tty: str | None, /) -> bool:
    """Validate that a TTY is still active and writable.

    Args:
        tty: The TTY path to validate (e.g., "/dev/ttys001")

    Returns:
        True if the TTY exists, is a character device, and is writable
    """
    if not tty:
        return False
    tty_path = Path(tty)
    try:
        return (
            tty_path.exists()
            and tty_path.is_char_device()
            and os.access(tty_path, os.W_OK)
        )
    except OSError:
        return False


def get_terminal_tty(tty: str | None, /) -> str | None:
    """Get the actual terminal TTY, resolving through tmux if needed.

    In tmux, the hook's TTY is the pane TTY (intercepted by tmux).
    We need the client TTY (connected to the actual terminal) to
    control the tab title via OSC escape sequences.

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
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if client_tty := result.stdout.strip():
            return client_tty
    except (subprocess.TimeoutExpired, OSError):
        pass

    return tty  # Fallback


def get_git_info(cwd: str, /) -> tuple[str | None, str | None, bool]:
    """Get git repo name, branch, and worktree status for the given directory.

    Returns:
        Tuple of (repo_name, branch_name, is_worktree).
        All fields are None/False if git is not installed or cwd is not a repo.
    """
    if not cwd:
        return None, None, False

    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
            cwd=cwd,
        )
        if result.returncode != 0:
            return None, None, False

        lines = result.stdout.strip().splitlines()
        if len(lines) < 2:
            return None, None, False

        repo_name = Path(lines[0]).name
        branch = lines[1] if lines[1] != "HEAD" else None  # Detached HEAD
    except subprocess.TimeoutExpired, OSError:
        return None, None, False

    # Detect worktree: git-common-dir != git-dir means we're in a worktree
    is_worktree = False
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--git-common-dir", "--git-dir"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
            cwd=cwd,
        )
        if result.returncode == 0:
            wt_lines = result.stdout.strip().splitlines()
            if len(wt_lines) == 2:
                is_worktree = Path(wt_lines[0]).resolve() != Path(wt_lines[1]).resolve()
    except subprocess.TimeoutExpired, OSError:
        pass

    return repo_name, branch, is_worktree


def update_tab_title(status: str, cwd: str, tty: str | None, /) -> None:
    """Update terminal tab title based on session status.

    Uses OSC 0 escape sequence to set the tab title. Works with
    Warp, iTerm2, Terminal.app, Ghostty, Kitty, WezTerm, and other
    terminals that support OSC 0.

    Args:
        status: The session status string
        cwd: The current working directory
        tty: The terminal TTY path to write to
    """
    if not tty:
        return

    project = Path(cwd).name if cwd else "unknown"
    title_map = {
        "waiting_for_input": f"\u23f8 Claude: {project}",
        "processing": f"\u26a1 Claude: {project}",
        "running_tool": f"\u26a1 Claude: {project}",
        "waiting_for_approval": f"\U0001f514 Claude: {project}",
        "compacting": f"\U0001f4e6 Claude: {project}",
        "ended": "",  # Clear title, restore terminal auto-title
    }
    title = title_map.get(status, f"\U0001f916 Claude: {project}")
    try:
        with open(tty, "w") as f:
            f.write(f"\033]0;{title}\007")
    except OSError:
        pass


def is_session_active(pid: int, tty: str | None, /) -> bool:
    """Check if the Claude Code session is still active.

    Combines PID existence check with TTY validation for robust detection.

    Args:
        pid: The process ID to check
        tty: The TTY path associated with the session

    Returns:
        True if the session appears active, False otherwise
    """
    # Check if process exists
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass  # Process exists but we lack permission to signal it

    # Validate TTY if available
    if tty and not validate_tty(tty):
        return False

    return True


def get_tty(ppid: int, /) -> str | None:
    """Get the TTY of the Claude process.

    Args:
        ppid: Parent process ID (Claude process)

    Returns:
        The TTY path (e.g., "/dev/ttys001") or None if unavailable
    """
    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if tty := result.stdout.strip():
            if tty not in ("??", "-"):
                # ps returns just "ttys001", we need "/dev/ttys001"
                return tty if tty.startswith("/dev/") else f"/dev/{tty}"
    except subprocess.TimeoutExpired, OSError:
        pass

    # Fallback: try current process stdin/stdout
    for fd in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(fd.fileno())
        except OSError, AttributeError:
            continue

    return None


def get_claude_pid() -> int:
    """Walk process tree to find Claude Code process PID.

    When hooks are run via 'uv run', os.getppid() returns uv's PID,
    which exits after the hook completes. This causes the session
    to disappear since the stored PID becomes invalid.

    This function walks up the process tree to find the actual
    Claude Code process (identified by command name 'claude').

    Returns:
        The PID of the Claude Code process, or falls back to immediate parent.
    """
    current_pid = os.getpid()

    for _ in range(10):  # Max depth to prevent infinite loops
        try:
            result = subprocess.run(
                ["ps", "-p", str(current_pid), "-o", "ppid=,comm="],
                capture_output=True,
                text=True,
                timeout=2,
                check=False,
            )
            if result.returncode != 0:
                break

            parts = result.stdout.strip().split()
            if len(parts) < 2:
                break

            ppid = int(parts[0])
            command = parts[1].lower()

            # Claude Code process shows as 'claude' in ps output
            if command == "claude":
                return current_pid

            current_pid = ppid
        except subprocess.TimeoutExpired, ValueError, OSError:
            break

    # Fallback to immediate parent
    return os.getppid()


def _all_keys_are_strings(d: dict[object, object], /) -> bool:
    """Check if all keys in a dictionary are strings."""
    for key in d:
        if not isinstance(key, str):
            return False
    return True


def _normalize_tool_input(value: object, /) -> ToolInputType:
    """Normalize tool_input to an empty dict unless it's actually a dict.

    Handles cases where hook payload contains "tool_input": null or other
    malformed content, ensuring the Swift decoder always receives a valid dict.

    Args:
        value: The raw tool_input value from the hook payload

    Returns:
        The value if it's a dict with string keys, otherwise an empty dict
    """
    if isinstance(value, dict) and _all_keys_are_strings(
        cast(dict[object, object], value)
    ):
        return cast(ToolInputType, value)
    return {}


def is_hook_event_data(obj: object, /) -> TypeIs[HookEventData]:
    """Validate that obj is a valid HookEventData dictionary.

    Args:
        obj: Object to validate (typically from json.load)

    Returns:
        True if obj is a valid HookEventData, False otherwise
    """
    if not isinstance(obj, dict):
        return False
    # HookEventData is total=False, so all keys are optional
    # Just verify it's a dict with string keys
    return _all_keys_are_strings(cast(dict[object, object], obj))


def is_permission_response(obj: object, /) -> TypeIs[PermissionResponse]:
    """Validate that obj is a valid PermissionResponse dictionary.

    Validates that the object is a dict with string keys, and that if
    decision/reason fields are present, they are strings.

    Args:
        obj: Object to validate (typically from json.loads)

    Returns:
        True if obj is a valid PermissionResponse, False otherwise
    """
    if not isinstance(obj, dict):
        return False
    if not _all_keys_are_strings(cast(dict[object, object], obj)):
        return False
    # Validate decision and reason are strings if present
    if "decision" in obj and not isinstance(obj["decision"], str):
        return False
    if "reason" in obj and not isinstance(obj["reason"], str):
        return False
    return True


def send_event(state: SessionState, /) -> PermissionResponse | None:
    """Send event to app, return response if any.

    Args:
        state: The session state to send

    Returns:
        Response dictionary for permission requests, None otherwise
    """
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(CONNECT_TIMEOUT_SECONDS)
            sock.connect(str(SOCKET_PATH))
            sock.sendall(json.dumps(state.to_dict()).encode())
            if state.status == "waiting_for_approval":
                sock.settimeout(PERMISSION_RECV_TIMEOUT_SECONDS)
                if response := sock.recv(4096):
                    parsed = cast(object, json.loads(response.decode()))
                    if is_permission_response(parsed):
                        return parsed
            return None
    except OSError, json.JSONDecodeError:
        return None


def determine_status(
    event: str,
    data: HookEventData,
    /,
) -> tuple[str, ToolExtras]:
    """Determine session status and extra fields from hook event.

    Uses pattern matching to dispatch on event type.

    Args:
        event: The hook event name
        data: The full event data dictionary

    Returns:
        Tuple of (status, extra_fields_dict)
    """
    match event:
        case "UserPromptSubmit":
            # User just sent a message - Claude is now processing
            return "processing", {}

        case "PreToolUse":
            extras_pre: ToolExtras = {}
            if tool := data.get("tool_name"):
                extras_pre["tool"] = tool
            extras_pre["tool_input"] = _normalize_tool_input(data.get("tool_input"))
            if tool_use_id := data.get("tool_use_id"):
                extras_pre["tool_use_id"] = tool_use_id
            return "running_tool", extras_pre

        case "PostToolUse":
            extras_post: ToolExtras = {}
            if tool := data.get("tool_name"):
                extras_post["tool"] = tool
            extras_post["tool_input"] = _normalize_tool_input(data.get("tool_input"))
            if tool_use_id := data.get("tool_use_id"):
                extras_post["tool_use_id"] = tool_use_id
            return "processing", extras_post

        case "PermissionRequest":
            extras_perm: ToolExtras = {
                "tool_input": _normalize_tool_input(data.get("tool_input"))
            }
            if tool := data.get("tool_name"):
                extras_perm["tool"] = tool
            if tool_use_id := data.get("tool_use_id"):
                extras_perm["tool_use_id"] = tool_use_id
            return "waiting_for_approval", extras_perm

        case "Notification":
            notification_type = data.get("notification_type")
            match notification_type:
                case "permission_prompt":
                    # Handled by PermissionRequest hook with better info
                    return "skip", {}
                case "idle_prompt":
                    extras_notif: ToolExtras = {}
                    if notification_type:
                        extras_notif["notification_type"] = notification_type
                    if msg := data.get("message"):
                        extras_notif["message"] = msg
                    return "waiting_for_input", extras_notif
                case _:
                    extras_other: ToolExtras = {}
                    if notification_type:
                        extras_other["notification_type"] = notification_type
                    if msg := data.get("message"):
                        extras_other["message"] = msg
                    return "notification", extras_other

        case "Stop":
            return "waiting_for_input", {}

        case "SubagentStop":
            # SubagentStop fires when a subagent completes - main session continues
            return "processing", {}

        case "SessionStart":
            # New session starts waiting for user input
            return "waiting_for_input", {}

        case "SessionEnd":
            return "ended", {}

        case "PreCompact":
            # Context is being compacted (manual or auto)
            return "compacting", {}

        case _:
            return "unknown", {}


def handle_permission_response(
    response: PermissionResponse | None,
    /,
    *,
    tool_name: str | None = None,
) -> None:
    """Handle the permission response from ClaudeIsland.app.

    Args:
        response: The response dictionary from the app, or None
        tool_name: The tool name from the hook event, used for always-allow rules
    """
    if not response:
        # No response or "ask" - let Claude Code show its normal UI
        print("{}")
        return

    decision = response.get("decision", "ask")
    reason = response.get("reason", "")

    match decision:
        case "allow":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        case "allow_always":
            # Add an allow rule to localSettings so the tool is never prompted again
            decision_payload: dict[str, object] = {"behavior": "allow"}
            if tool_name:
                decision_payload["updatedPermissions"] = [
                    {
                        "type": "addRules",
                        "rules": [{"toolName": tool_name}],
                        "behavior": "allow",
                        "destination": "localSettings",
                    }
                ]
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": decision_payload,
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        case "deny":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": reason or "Denied by user via ClaudeIsland",
                    },
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        case _decision:
            # "ask" or unknown - let Claude Code show its normal UI
            print("{}")


def main() -> None:
    """Main entry point for the hook."""
    try:
        raw_data = cast(object, json.load(sys.stdin))
    except json.JSONDecodeError:
        sys.exit(1)

    if not is_hook_event_data(raw_data):
        sys.exit(1)
    data: HookEventData = raw_data

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")

    # Determine status early (pure computation, no I/O)
    status, extras = determine_status(event, data)

    # Skip certain events (e.g. stale PreToolUse registration)
    if status == "skip":
        print("{}")
        sys.exit(0)

    # Resolve PID, TTY, build state
    claude_pid = get_claude_pid()
    tty = get_tty(claude_pid)

    # Resolve terminal TTY (client TTY in tmux, same as tty otherwise)
    terminal_tty = get_terminal_tty(tty)

    # Update terminal tab title via OSC 0 escape sequence
    update_tab_title(status, cwd, terminal_tty)

    # Collect git info (repo name, branch, worktree status)
    git_repo_name, git_branch, git_is_worktree = get_git_info(cwd)

    state = SessionState(
        session_id=session_id,
        cwd=cwd,
        event=event,
        pid=claude_pid,
        tty=tty,
        tty_valid=validate_tty(tty),
        session_active=is_session_active(claude_pid, tty),
        status=status,
        terminal_tty=terminal_tty,
        tool=extras.get("tool"),
        tool_input=_normalize_tool_input(extras.get("tool_input")),
        tool_use_id=extras.get("tool_use_id"),
        notification_type=extras.get("notification_type"),
        message=extras.get("message"),
        git_repo_name=git_repo_name,
        git_branch=git_branch,
        git_is_worktree=git_is_worktree,
    )

    # Forward to Warp's CLI Agent subsystem (no-op outside Warp).
    # Runs *before* send_event so the tab status dot updates even if the
    # ClaudeIsland app socket is unreachable.
    emit_warp_cli_agent_event(state, terminal_tty)

    # Send to ClaudeIsland.app
    response = send_event(state)

    # Permission requests return the decision; all others print empty JSON
    if status == "waiting_for_approval":
        handle_permission_response(response, tool_name=state.tool)
    else:
        print("{}")


if __name__ == "__main__":
    main()
