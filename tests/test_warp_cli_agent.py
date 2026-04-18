#!/usr/bin/env python3
# /// script
# requires-python = ">=3.14"
# ///
"""Tests for the Warp CLI Agent integration in claude-island-state.py.

Run with: `uv run tests/test_warp_cli_agent.py`

Why no pytest: the hook script is the only Python in the repo and it's
invoked via uv with no installed test framework. Stdlib unittest keeps the
test runnable in any environment without extra setup.
"""

import importlib.util
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from typing import Any
from unittest import mock


# Load the hook script as a module despite the hyphen in its filename.
def _load_hook_module() -> Any:
    repo_root = Path(__file__).resolve().parent.parent
    script_path = repo_root / "ClaudeIsland" / "Resources" / "claude-island-state.py"
    spec = importlib.util.spec_from_file_location("claude_island_state", script_path)
    if spec is None or spec.loader is None:
        msg = f"Failed to load spec for {script_path}"
        raise RuntimeError(msg)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HOOK = _load_hook_module()


def _make_state(**overrides: Any) -> Any:
    """Build a SessionState with sensible defaults for tests."""
    defaults: dict[str, Any] = {
        "session_id": "abc-123",
        "cwd": "/Users/me/projects/myproj",
        "event": "Notification",
        "pid": 4242,
        "tty": "/dev/ttys001",
        "tty_valid": True,
        "session_active": True,
        "status": "waiting_for_input",
    }
    defaults.update(overrides)
    return HOOK.SessionState(**defaults)


class HookEventMappingTests(unittest.TestCase):
    """Each Claude Code hook event maps to exactly one CLI Agent event, and
    unmapped hooks (SessionEnd, SubagentStop, PreCompact) must NOT emit — those
    have no official Warp-side semantics and would desynchronize the tab state.
    """

    def test_known_hooks_map_to_cli_events(self) -> None:
        expected = {
            "SessionStart": "session_start",
            "UserPromptSubmit": "prompt_submit",
            "PostToolUse": "tool_complete",
            "PreToolUse": "permission_request",
            "Notification": "idle_prompt",
            "Stop": "stop",
        }
        for hook_event, cli_event in expected.items():
            with self.subTest(hook=hook_event):
                self.assertEqual(HOOK.HOOK_EVENT_TO_CLI_AGENT.get(hook_event), cli_event)

    def test_unmapped_hooks_have_no_entry(self) -> None:
        for unmapped in ("SessionEnd", "SubagentStop", "PreCompact", "Unknown"):
            with self.subTest(hook=unmapped):
                self.assertNotIn(unmapped, HOOK.HOOK_EVENT_TO_CLI_AGENT)


class ShouldEmitGateTests(unittest.TestCase):
    """The gate must close on every non-Warp environment so we don't spam OSC
    777 frames into terminals that may interpret them differently."""

    def setUp(self) -> None:
        self.env_patcher = mock.patch.dict(os.environ, {}, clear=False)
        self.env_patcher.start()
        # Reset a clean slate.
        for key in ("TERM_PROGRAM", "WARP_CLI_AGENT_PROTOCOL_VERSION", "TERM_PROGRAM_VERSION"):
            os.environ.pop(key, None)
        # Make _load_hook_config return empty (config file may exist on dev machine).
        self.cfg_patcher = mock.patch.object(HOOK, "_load_hook_config", return_value={})
        self.cfg_patcher.start()

    def tearDown(self) -> None:
        self.env_patcher.stop()
        self.cfg_patcher.stop()

    def test_no_term_program_env_returns_false(self) -> None:
        self.assertFalse(HOOK.should_emit_warp_cli_agent())

    def test_iterm_returns_false(self) -> None:
        os.environ["TERM_PROGRAM"] = "iTerm.app"
        os.environ["WARP_CLI_AGENT_PROTOCOL_VERSION"] = "1"
        self.assertFalse(HOOK.should_emit_warp_cli_agent())

    def test_warp_without_protocol_version_returns_false(self) -> None:
        os.environ["TERM_PROGRAM"] = "WarpTerminal"
        # Old Warp without the env var advertised — must downgrade silently.
        self.assertFalse(HOOK.should_emit_warp_cli_agent())

    def test_warp_with_protocol_version_returns_true(self) -> None:
        os.environ["TERM_PROGRAM"] = "WarpTerminal"
        os.environ["WARP_CLI_AGENT_PROTOCOL_VERSION"] = "1"
        self.assertTrue(HOOK.should_emit_warp_cli_agent())

    def test_blacklisted_warp_version_returns_false(self) -> None:
        os.environ["TERM_PROGRAM"] = "WarpTerminal"
        os.environ["WARP_CLI_AGENT_PROTOCOL_VERSION"] = "1"
        os.environ["TERM_PROGRAM_VERSION"] = "0.bad.version"
        with mock.patch.object(HOOK, "WARP_BAD_VERSIONS", frozenset({"0.bad.version"})):
            with redirect_stderr(io.StringIO()):  # swallow the diagnostic line
                self.assertFalse(HOOK.should_emit_warp_cli_agent())

    def test_island_only_mode_returns_false(self) -> None:
        os.environ["TERM_PROGRAM"] = "WarpTerminal"
        os.environ["WARP_CLI_AGENT_PROTOCOL_VERSION"] = "1"
        with mock.patch.object(HOOK, "_load_hook_config", return_value={"warpCLIAgentMode": "island-only"}):
            self.assertFalse(HOOK.should_emit_warp_cli_agent())

    def test_explicit_disable_returns_false(self) -> None:
        os.environ["TERM_PROGRAM"] = "WarpTerminal"
        os.environ["WARP_CLI_AGENT_PROTOCOL_VERSION"] = "1"
        with mock.patch.object(HOOK, "_load_hook_config", return_value={"warpCLIAgentEnabled": False}):
            self.assertFalse(HOOK.should_emit_warp_cli_agent())


class FrameFormatTests(unittest.TestCase):
    """The OSC 777 frame must match Warp's expected wire format exactly:
    `\\033]777;notify;warp://cli-agent;<json>\\007`.
    """

    def setUp(self) -> None:
        # Force the gate open so emit_warp_cli_agent_event reaches the write path.
        self.should_patcher = mock.patch.object(HOOK, "should_emit_warp_cli_agent", return_value=True)
        self.should_patcher.start()

    def tearDown(self) -> None:
        self.should_patcher.stop()

    def _capture_frame(
        self,
        state: Any,
        terminal_tty: str = "/dev/ttys001",
        raw_data: dict[str, Any] | None = None,
    ) -> str | None:
        """Run emit and return whatever bytes were written via builtins.open."""
        captured: dict[str, str] = {}
        real_open = open

        class _FakeFile:
            def __init__(self) -> None:
                self.buf = io.StringIO()

            def __enter__(self) -> "_FakeFile":
                return self

            def __exit__(self, *_a: object) -> None:
                captured["frame"] = self.buf.getvalue()

            def write(self, s: str) -> int:
                return self.buf.write(s)

        def fake_open(path: str, mode: str = "r", *a: Any, **kw: Any) -> Any:
            # Only intercept writes to the terminal TTY. Other opens (config
            # file, transcript path) go through to the real filesystem so
            # the stop path can still read transcripts in tests that supply one.
            if path == terminal_tty:
                captured["path"] = path
                return _FakeFile()
            return real_open(path, mode, *a, **kw)

        with mock.patch("builtins.open", side_effect=fake_open):
            HOOK.emit_warp_cli_agent_event(state, terminal_tty, raw_data)

        return captured.get("frame")

    def _extract_payload(self, frame: str | None) -> dict[str, Any]:
        self.assertIsNotNone(frame, "emit should have written a frame")
        assert frame is not None
        self.assertTrue(frame.startswith("\033]777;notify;warp://cli-agent;"))
        self.assertTrue(frame.endswith("\007"))
        body = frame[len("\033]777;notify;warp://cli-agent;") : -1]
        result = json.loads(body)
        assert isinstance(result, dict)
        return result

    def test_idle_prompt_frame_shape(self) -> None:
        state = _make_state(event="Notification", message="Claude is idle")
        payload = self._extract_payload(self._capture_frame(state))
        self.assertEqual(payload["event"], "idle_prompt")
        self.assertEqual(payload["agent"], "claude")
        self.assertEqual(payload["session_id"], "abc-123")
        self.assertEqual(payload["project"], "myproj")
        self.assertEqual(payload["summary"], "Claude is idle")

    def test_session_start_includes_plugin_version(self) -> None:
        state = _make_state(event="SessionStart")
        payload = self._extract_payload(self._capture_frame(state))
        self.assertEqual(payload["event"], "session_start")
        self.assertEqual(payload["plugin_version"], HOOK.WARP_PLUGIN_VERSION)

    def test_prompt_submit_includes_user_query(self) -> None:
        state = _make_state(event="UserPromptSubmit")
        payload = self._extract_payload(
            self._capture_frame(state, raw_data={"prompt": "what is 2+2"}),
        )
        self.assertEqual(payload["event"], "prompt_submit")
        self.assertEqual(payload["query"], "what is 2+2")

    def test_prompt_submit_truncates_long_query(self) -> None:
        long_prompt = "x" * 500
        state = _make_state(event="UserPromptSubmit")
        payload = self._extract_payload(
            self._capture_frame(state, raw_data={"prompt": long_prompt}),
        )
        self.assertTrue(payload["query"].endswith("..."))
        self.assertLessEqual(len(payload["query"]), 200)

    def test_permission_request_includes_tool_summary(self) -> None:
        state = _make_state(
            event="PreToolUse",
            tool="Bash",
            tool_input={"command": "rm -rf /tmp/foo"},
        )
        payload = self._extract_payload(self._capture_frame(state))
        self.assertEqual(payload["event"], "permission_request")
        self.assertEqual(payload["tool_name"], "Bash")
        self.assertEqual(payload["summary"], "Run Bash: rm -rf /tmp/foo")

    def test_tool_complete_includes_tool_name(self) -> None:
        state = _make_state(event="PostToolUse", tool="Read")
        payload = self._extract_payload(self._capture_frame(state))
        self.assertEqual(payload["event"], "tool_complete")
        self.assertEqual(payload["tool_name"], "Read")

    def test_stop_includes_query_response_transcript(self) -> None:
        # Write a tiny fake transcript so _extract_stop_context can read it.
        import tempfile

        transcript = (
            '{"type":"user","message":{"content":"hello"}}\n'
            '{"type":"assistant","message":{"content":[{"type":"text","text":"hi there"}]}}\n'
        )
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonl", delete=False, encoding="utf-8",
        ) as f:
            f.write(transcript)
            tpath = f.name

        try:
            state = _make_state(event="Stop")
            with mock.patch.object(HOOK.time, "sleep"):  # skip the 0.3s flush delay
                payload = self._extract_payload(
                    self._capture_frame(state, raw_data={"transcript_path": tpath}),
                )
            self.assertEqual(payload["event"], "stop")
            self.assertEqual(payload["query"], "hello")
            self.assertEqual(payload["response"], "hi there")
            self.assertEqual(payload["transcript_path"], tpath)
        finally:
            os.unlink(tpath)

    def test_stop_skips_when_stop_hook_active(self) -> None:
        # stop_hook_active=True means Claude is already inside its stop chain —
        # emitting again would produce a duplicate toast.
        state = _make_state(event="Stop")
        with mock.patch("builtins.open", side_effect=AssertionError("open should not be called")):
            HOOK.emit_warp_cli_agent_event(state, "/dev/ttys001", {"stop_hook_active": True})

    def test_no_tty_means_no_frame(self) -> None:
        state = _make_state(event="Notification")
        with mock.patch("builtins.open", side_effect=AssertionError("open should not be called")):
            HOOK.emit_warp_cli_agent_event(state, None)

    def test_unmapped_hook_means_no_frame(self) -> None:
        state = _make_state(event="SessionEnd")  # not in HOOK_EVENT_TO_CLI_AGENT
        with mock.patch("builtins.open", side_effect=AssertionError("open should not be called")):
            HOOK.emit_warp_cli_agent_event(state, "/dev/ttys001")


class PermissionSummaryTests(unittest.TestCase):
    """`_permission_summary` formats the human-readable preview that surfaces
    in Warp's notification body. Truncation must kick in on long commands so
    the macOS notification doesn't get clipped mid-word."""

    def test_bash_short(self) -> None:
        state = _make_state(tool="Bash", tool_input={"command": "ls"})
        self.assertEqual(HOOK._permission_summary(state), "Run Bash: ls")

    def test_bash_truncates_long(self) -> None:
        long_cmd = "echo " + ("x" * 200)
        state = _make_state(tool="Bash", tool_input={"command": long_cmd})
        result = HOOK._permission_summary(state)
        self.assertTrue(result.startswith("Run Bash: echo "))
        self.assertTrue(result.endswith("..."))
        self.assertLessEqual(len(result), len("Run Bash: ") + 80)

    def test_edit_uses_file_path(self) -> None:
        state = _make_state(tool="Edit", tool_input={"file_path": "/etc/hosts"})
        self.assertEqual(HOOK._permission_summary(state), "Edit: /etc/hosts")

    def test_unknown_tool_falls_back(self) -> None:
        state = _make_state(tool="MyMcpTool", tool_input={})
        self.assertEqual(HOOK._permission_summary(state), "Use MyMcpTool")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
