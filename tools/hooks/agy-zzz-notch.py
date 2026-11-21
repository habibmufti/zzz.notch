#!/usr/bin/env python3
"""Antigravity lifecycle hook -> zzz.notch.

Configure in ~/.gemini/config/hooks.json (global) or .agents/hooks.json (workspace).
Reads Antigravity's camelCase hook payload from stdin, fires `zzz` asynchronously
so the synchronous hook never stalls the agent loop, and prints the required
JSON response to stdout.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ZZZ = os.environ.get("ZZZ_BIN") or os.path.join(os.path.expanduser("~"), ".local/bin/zzz")
DETAIL_INTERVAL_S = 0.8

TERM_BUNDLE_IDS = {
    "ghostty": "com.mitchellh.ghostty",
    "iTerm.app": "com.googlecode.iterm2",
    "Apple_Terminal": "com.apple.Terminal",
    "WezTerm": "com.github.wez.wezterm",
    "WarpTerminal": "dev.warp.Warp-Stable",
    "vscode": "com.microsoft.VSCode",
}

NOW_LABELS = {
    "run_command": "Running a command",
    "read_file": "Reading",
    "view_file": "Reading",
    "write_file": "Writing a file",
    "edit_file": "Editing",
    "replace_file_content": "Editing",
    "multi_replace_file_content": "Editing",
    "search_web": "Searching the web",
    "grep_search": "Searching code",
    "find_by_name": "Finding files",
    "list_dir": "Listing files",
    "codebase_search": "Searching code",
    "invoke_subagent": "Starting subagent",
    "run_workflow": "Running workflow",
    "ask_question": "Waiting for your answer",
}

PUSH_RE = re.compile(r"\bgit\s+push\b|\bgh\s+(pr\s+create|release)\b")
BUILD_RE = re.compile(
    r"\b(build|make|cargo|xcodebuild|swiftc?|tsc|bun\s+(run|test)|npm\s+(run|test)"
    r"|pytest|go\s+(build|test)|gh\s+run\s+watch)\b"
)
SEARCH_RE = re.compile(r"\b(rg|grep|fd|find)\b")
MD_NOISE_RE = re.compile(r"[`*_#>]")
SPACE_RE = re.compile(r"\s+")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+|\n")
MD_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]+\)")


def one_line(text: str, limit: int) -> str:
    cleaned = MD_LINK_RE.sub(r"\1", text)
    cleaned = MD_NOISE_RE.sub("", cleaned)
    cleaned = SPACE_RE.sub(" ", cleaned).strip()
    if len(cleaned) > limit:
        return cleaned[: limit - 1] + "…"
    return cleaned


def shorten_path(raw: str, root: str) -> str:
    if not raw:
        return ""
    if root:
        prefix = root.rstrip("/") + "/"
        if raw.startswith(prefix):
            return raw[len(prefix) :]
    home = os.path.expanduser("~").rstrip("/") + "/"
    if raw.startswith(home):
        return "~/" + raw[len(home) :]
    return raw


def detect_app_bundle(payload: dict[str, Any]) -> str:
    bundle = os.environ.get("__CFBundleIdentifier", "").strip()
    if bundle:
        return bundle
    term = os.environ.get("TERM_PROGRAM", "").strip()
    if term in TERM_BUNDLE_IDS:
        return TERM_BUNDLE_IDS[term]
    return ""


def workspace_root(payload: dict[str, Any]) -> str:
    paths = payload.get("workspacePaths")
    if isinstance(paths, list) and paths and isinstance(paths[0], str) and paths[0]:
        return paths[0]
    cwd = payload.get("cwd")
    if isinstance(cwd, str) and cwd:
        return cwd
    return ""


def state_file_path(session_id: str) -> Path:
    uid = os.getuid()
    safe = re.sub(r"[^a-zA-Z0-9._-]", "_", session_id)
    return Path(f"/tmp/zzz-agy-{uid}-{safe}.json")


def load_state(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(path: Path, state: dict[str, Any]) -> None:
    try:
        path.write_text(json.dumps(state), encoding="utf-8")
    except Exception:
        pass


def final_summary(transcript_path: str) -> str | None:
    if not transcript_path:
        return None
    p = Path(transcript_path)
    if not p.is_file():
        return None
    try:
        size = p.stat().st_size
        with p.open("rb") as f:
            if size > 65536:
                f.seek(size - 65536)
                f.readline()  # discard partial line
            lines = f.read().decode("utf-8", errors="ignore").splitlines()
    except Exception:
        return None

    for raw in reversed(lines):
        if not raw.strip():
            continue
        try:
            entry = json.loads(raw)
        except Exception:
            continue
        if entry.get("type") != "PLANNER_RESPONSE" or entry.get("source") != "MODEL":
            continue
        content = entry.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        paragraph = re.split(r"\n\s*\n", content.strip(), maxsplit=1)[0].strip()
        first = SENTENCE_SPLIT_RE.split(paragraph, maxsplit=1)[0].strip()
        pick = paragraph if len(first) < 25 else first
        if pick:
            return one_line(pick, 140)
    return None


def activity_of(tool: str, args: dict[str, Any]) -> str:
    cmd = str(args.get("CommandLine") or args.get("command") or "")
    if PUSH_RE.search(cmd):
        return "push"
    if BUILD_RE.search(cmd) or tool == "run_workflow":
        return "build"
    if tool in ("search_web", "grep_search", "find_by_name", "list_dir", "codebase_search") or SEARCH_RE.search(cmd):
        return "search"
    if tool in ("read_file", "view_file"):
        return "read"
    return "type"


def describe_tool(tool: str, args: dict[str, Any], root: str) -> tuple[str, str, str, str]:
    """Return (detail, now_headline, intent, command)."""
    if tool == "call_mcp_tool":
        server = str(args.get("ServerName") or "mcp")
        mcp_tool = str(args.get("ToolName") or "")
        now = f"MCP · {server}"
        detail = one_line(f"{server}: {mcp_tool}" if mcp_tool else server, 120)
        return detail, now, "", one_line(mcp_tool, 160)

    if tool == "invoke_subagent":
        role = one_line(str(args.get("Role") or args.get("TypeName") or "Subagent"), 100)
        prompt = one_line(str(args.get("Prompt") or ""), 120)
        return one_line(f"subagent: {role}", 120), "Starting subagent", role, prompt

    if tool == "run_command":
        cmd = one_line(str(args.get("CommandLine") or args.get("command") or ""), 160)
        intent = one_line(str(args.get("toolSummary") or ""), 120)
        detail = one_line(f"bash: {intent or cmd}", 120)
        return detail, NOW_LABELS[tool], intent, cmd

    if tool in ("read_file", "view_file", "write_file", "edit_file", "replace_file_content", "multi_replace_file_content"):
        raw_path = str(args.get("Path") or args.get("TargetFile") or args.get("AbsolutePath") or "")
        short = shorten_path(raw_path, root)
        verb = "read" if tool in ("read_file", "view_file") else ("write" if tool == "write_file" else "edit")
        detail = one_line(f"{verb}: {short}" if short else verb, 120)
        return detail, NOW_LABELS.get(tool, f"Using {tool}"), "", one_line(short, 160)

    target = ""
    for key in ("query", "Query", "Pattern", "Description", "DirectoryPath", "Path", "url"):
        val = args.get(key)
        if isinstance(val, str) and val.strip():
            target = shorten_path(val.strip(), root) if key in ("DirectoryPath", "Path") else val.strip()
            break
    now = NOW_LABELS.get(tool, f"Using {tool}")
    detail = one_line(f"{tool}: {target}" if target else tool, 120)
    return detail, now, "", one_line(target, 160)


def build_notify_args(
    title: str,
    body: str,
    status: str,
    session_id: str,
    app_bundle: str,
    extra: list[str] | None = None,
) -> list[str]:
    args = [
        ZZZ,
        "notify",
        title,
        body,
        "--source",
        "agy",
        "--status",
        status,
        "--symbol",
        "sparkles",
        "--id",
        session_id,
    ]
    if app_bundle:
        args.extend(["--app", app_bundle])
    if extra:
        args.extend(extra)
    return args


def fire_async(cmd: list[str]) -> None:
    if os.environ.get("ZZZ_DRY_RUN"):
        subprocess.run(cmd, stdout=sys.stderr, check=False)
        return
    if not os.path.exists(ZZZ):
        return
    subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def fire_sequence_async(first: list[str], second: list[str], delay_s: float = 0.25) -> None:
    if os.environ.get("ZZZ_DRY_RUN"):
        subprocess.run(first, stdout=sys.stderr, check=False)
        subprocess.run(second, stdout=sys.stderr, check=False)
        return
    if not os.path.exists(ZZZ):
        return
    script = (
        f"{' '.join(shlex.quote(a) for a in first)} >/dev/null 2>&1; "
        f"sleep {delay_s}; "
        f"{' '.join(shlex.quote(a) for a in second)} >/dev/null 2>&1"
    )
    subprocess.Popen(
        ["/bin/sh", "-c", script],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def handle_event(payload: dict[str, Any]) -> None:
    event = str(payload.get("hookEventName") or "")
    conv_id = str(payload.get("conversationId") or os.getppid())
    session_id = f"agy-{conv_id[:12]}"
    root = workspace_root(payload)
    project = os.path.basename(root.rstrip("/")) if root else "Antigravity"
    app_bundle = detect_app_bundle(payload)

    st_path = state_file_path(session_id)
    state = load_state(st_path)
    now_ts = time.monotonic()

    prompt_raw = payload.get("lastUserInput")
    prompt = one_line(prompt_raw, 160) if isinstance(prompt_raw, str) and prompt_raw.strip() else state.get("prompt", "")

    if event == "SessionStart":
        state.update({"status": "idle", "last_ts": now_ts, "prompt": prompt})
        save_state(st_path, state)
        fire_async(build_notify_args(project, "Idle", "idle", session_id, app_bundle))
        return

    if event == "PreInvocation":
        prev_status = state.get("status")
        prev_prompt = state.get("prompt", "")
        if prev_status == "run" and prev_prompt == prompt and (now_ts - float(state.get("last_ts", 0))) < DETAIL_INTERVAL_S:
            return
        state.update({"status": "run", "last_ts": now_ts, "prompt": prompt})
        save_state(st_path, state)
        extra = ["--prompt", prompt] if prompt else []
        fire_async(build_notify_args(project, "Working", "run", session_id, app_bundle, extra))
        return

    if event == "PreToolUse":
        tool_call = payload.get("toolCall") or {}
        tool = str(tool_call.get("name") or "")
        args = tool_call.get("args") if isinstance(tool_call.get("args"), dict) else {}

        if tool == "ask_question":
            questions = args.get("questions")
            q_text = "Waiting for your answer"
            if isinstance(questions, list) and questions and isinstance(questions[0], dict):
                q = questions[0].get("question")
                if isinstance(q, str) and q.strip():
                    q_text = one_line(q, 140)
            state.update({"status": "wait", "last_ts": now_ts, "prompt": prompt})
            save_state(st_path, state)
            extra = ["--prompt", prompt] if prompt else []
            fire_async(build_notify_args(project, q_text, "wait", session_id, app_bundle, extra))
            return

        if state.get("status") == "run" and (now_ts - float(state.get("last_ts", 0))) < DETAIL_INTERVAL_S:
            return

        detail, now_label, intent, command = describe_tool(tool, args, root)
        activity = activity_of(tool, args)
        extra = ["--detail", detail, "--activity", activity, "--now", now_label]
        if intent:
            extra.extend(["--intent", intent])
        if command:
            extra.extend(["--command", command])
        if prompt:
            extra.extend(["--prompt", prompt])

        state.update({"status": "run", "last_ts": now_ts, "prompt": prompt})
        save_state(st_path, state)
        fire_async(build_notify_args(project, "Working", "run", session_id, app_bundle, extra))
        return

    if event == "PostToolUse":
        tool_call = payload.get("toolCall") or {}
        if tool_call.get("name") == "ask_question":
            state.update({"status": "run", "last_ts": now_ts, "prompt": prompt})
            save_state(st_path, state)
            extra = ["--prompt", prompt] if prompt else []
            fire_async(build_notify_args(project, "Working", "run", session_id, app_bundle, extra))
        return

    if event == "Stop":
        reason = str(payload.get("terminationReason") or "")
        error = str(payload.get("error") or "").strip()
        transcript = str(payload.get("transcriptPath") or "")

        state.update({"status": "idle", "last_ts": now_ts, "prompt": prompt})
        save_state(st_path, state)
        extra = ["--prompt", prompt] if prompt else []

        if reason == "ERROR" or error:
            msg = one_line(error or "Execution error", 140)
            fire_sequence_async(
                build_notify_args(project, msg, "fail", session_id, app_bundle, extra),
                build_notify_args(project, msg, "idle", session_id, app_bundle, extra),
            )
        elif reason == "USER_CANCELED":
            fire_async(build_notify_args(project, "Canceled", "idle", session_id, app_bundle, extra))
        else:
            summary = final_summary(transcript) or "Done"
            fire_sequence_async(
                build_notify_args(project, summary, "ok", session_id, app_bundle, extra),
                build_notify_args(project, summary, "idle", session_id, app_bundle, extra),
            )


def response_for(event: str) -> dict[str, Any]:
    if event == "PreToolUse":
        return {"decision": "allow"}
    if event == "Stop":
        return {"decision": "stop"}
    return {}


def main() -> None:
    event = ""
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if isinstance(payload, dict):
            event = str(payload.get("hookEventName") or "")
            handle_event(payload)
    except Exception:
        pass
    finally:
        sys.stdout.write(json.dumps(response_for(event)) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
