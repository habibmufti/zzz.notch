#!/usr/bin/env python3
"""Antigravity lifecycle hook -> zzz.notch.

Configure in ~/.gemini/config/hooks.json (global) or .agents/hooks.json (workspace).
Reads Antigravity's camelCase hook payload from stdin, fires `zzz` asynchronously
so the synchronous hook never stalls the agent loop, and prints the required
JSON response to stdout.

Matches `omp-zzz-notch.ts` semantics:
- One mascot per Antigravity host process (`agy-<pid>`, falling back to
  `agy-<conv_id[:12]>` if PID detection fails), so `/new` or switching chats
  in the same `agy` terminal reuses the same card without leaving ghosts.
- Subagents (transcripts starting with a SYSTEM_MESSAGE bearing `sender=<parent>`)
  do not spawn their own mascot; instead they aggregate into the parent session's
  `--agents` badge and `--agent-list` card section.
- On `Stop`, completed turns celebrate (`ok`/`fail`) then return to `idle`
  (keeping `LAST RESULT` and dozing off after 3 min). When the `agy` terminal
  process exits, `zzz.notch`'s `--pid` watcher removes the session automatically.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any, Iterator

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
SUBAGENT_SENDER_RE = re.compile(r"\[Message\][^\n]*\bsender=([0-9a-fA-F-]{8,})")
SUBAGENT_CONTENT_RE = re.compile(r"\[Message\][^\n]*\bcontent=(.+)", re.DOTALL)


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


def detect_action_url(root: str, app_bundle: str) -> str:
    if not root:
        return ""
    term = os.environ.get("TERM_PROGRAM", "").strip()
    if app_bundle == "com.microsoft.VSCode" or term == "vscode":
        return "vscode://file" + urllib.parse.quote(root, safe="/")
    if app_bundle == "com.todesktop.230313mzl4w4u92":
        return "cursor://file" + urllib.parse.quote(root, safe="/")
    return ""


def detect_host_pid() -> int | None:
    """Walk past transient sh/bash/zsh hook wrappers to find the persistent host PID."""
    override = os.environ.get("ZZZ_HOST_PID", "").strip()
    if override.isdigit() and int(override) > 1:
        return int(override)
    pid = os.getppid()
    for _ in range(5):
        if pid <= 1:
            return None
        try:
            out = subprocess.check_output(
                ["/bin/ps", "-o", "ppid=,comm=", "-p", str(pid)],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=0.3,
            ).strip()
        except Exception:
            return pid
        parts = out.split(None, 1)
        if len(parts) < 2:
            return pid
        ppid_str, comm = parts[0], os.path.basename(parts[1].strip())
        if comm in ("sh", "bash", "zsh", "dash", "env"):
            try:
                pid = int(ppid_str)
                continue
            except ValueError:
                return pid
        return pid
    return pid if pid > 1 else None


def context_window_for(model: str) -> int:
    m = model.lower()
    if "gemini" in m or "[1m]" in m:
        return 1_000_000
    return 200_000


def inspect_transcript_origin(transcript_path: str) -> tuple[bool | None, str | None, str]:
    """Read step 0 of transcript.jsonl to distinguish main agent vs subagent.

    Returns (is_subagent, parent_conversation_id, task_snippet).
    """
    if not transcript_path:
        return None, None, ""
    p = Path(transcript_path)
    if not p.is_file():
        return None, None, ""
    try:
        with p.open("r", encoding="utf-8", errors="ignore") as f:
            first_line = f.readline().strip()
    except Exception:
        return None, None, ""
    if not first_line:
        return None, None, ""
    try:
        entry = json.loads(first_line)
    except Exception:
        return None, None, ""

    entry_type = str(entry.get("type") or "")
    entry_source = str(entry.get("source") or "")
    if entry_type == "USER_INPUT" or entry_source == "USER_EXPLICIT":
        return False, None, ""
    if entry_type == "SYSTEM_MESSAGE" or entry_source == "SYSTEM":
        content = str(entry.get("content") or "")
        sender_match = SUBAGENT_SENDER_RE.search(content)
        parent_id = sender_match.group(1) if sender_match else None
        task = ""
        content_match = SUBAGENT_CONTENT_RE.search(content)
        if content_match:
            raw_task = content_match.group(1).split("</SYSTEM_MESSAGE>", 1)[0].strip()
            first_para = raw_task.splitlines()[0].strip() if raw_task else ""
            task = one_line(first_para, 80)
        return True, parent_id, task
    return None, None, ""


def transcript_metrics(transcript_path: str) -> tuple[str | None, int | None]:
    """Read tail of transcript.jsonl once to get (final_summary, context_percent)."""
    if not transcript_path:
        return None, None
    p = Path(transcript_path)
    if not p.is_file():
        return None, None
    try:
        size = p.stat().st_size
        with p.open("rb") as f:
            if size > 65536:
                f.seek(size - 65536)
                f.readline()  # discard partial line
            lines = f.read().decode("utf-8", errors="ignore").splitlines()
    except Exception:
        return None, None

    summary: str | None = None
    context_pct: int | None = None

    for raw in reversed(lines):
        if not raw.strip():
            continue
        try:
            entry = json.loads(raw)
        except Exception:
            continue
        if entry.get("type") != "PLANNER_RESPONSE" or entry.get("source") != "MODEL":
            continue
        if context_pct is None:
            try:
                inp = int(entry.get("input_tokens") or 0)
                cached = int(entry.get("cache_read_tokens") or 0)
                total = inp + cached
                if total > 0:
                    window = context_window_for(str(entry.get("model") or ""))
                    context_pct = min(100, max(1, round(total * 100 / window)))
            except Exception:
                pass
        if summary is None:
            content = entry.get("content")
            if isinstance(content, str) and content.strip():
                paragraph = re.split(r"\n\s*\n", content.strip(), maxsplit=1)[0].strip()
                first = SENTENCE_SPLIT_RE.split(paragraph, maxsplit=1)[0].strip()
                pick = paragraph if len(first) < 25 else first
                if pick:
                    summary = one_line(pick, 140)
        if summary is not None and context_pct is not None:
            break

    return summary, context_pct


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


@contextlib.contextmanager
def state_lock(path: Path) -> Iterator[None]:
    lock_path = path.with_suffix(".lock")
    fd = None
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    except Exception:
        yield
    finally:
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
            except Exception:
                pass


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


def subagent_extra_args(state: dict[str, Any]) -> list[str]:
    active = state.get("active_subagents")
    if not isinstance(active, dict):
        return ["--agents", "0"]
    labels = [str(v) for v in active.values() if isinstance(v, str) and v.strip()]
    args = ["--agents", str(len(active))]
    if labels:
        args.extend(["--agent-list", "\n".join(labels)])
    return args


def build_notify_args(
    title: str,
    body: str,
    status: str,
    session_id: str,
    app_bundle: str,
    action_url: str = "",
    host_pid: int | None = None,
    context_pct: int | None = None,
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
    if action_url:
        args.extend(["--url", action_url])
    if host_pid:
        args.extend(["--pid", str(host_pid)])
    if context_pct is not None:
        args.extend(["--context", str(context_pct)])
    tmux_pane = os.environ.get("TMUX_PANE", "").strip()
    if tmux_pane:
        args.extend(["--tmux", tmux_pane])
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


def update_parent_subagent(
    parent_sid: str,
    sub_conv_id: str,
    adding: bool,
    fallback_task: str,
    project: str,
    app_bundle: str,
    action_url: str,
) -> None:
    """Register or unregister a subagent on its parent session's badge/card."""
    parent_path = state_file_path(parent_sid)

    with state_lock(parent_path):
        parent_state = load_state(parent_path)
        if not parent_state:
            return
        active = parent_state.get("active_subagents")
        if not isinstance(active, dict):
            active = {}

        changed = False
        if adding:
            if sub_conv_id not in active:
                pending = parent_state.get("pending_subagents")
                label = ""
                if isinstance(pending, list) and pending:
                    label = str(pending.pop(0))
                    parent_state["pending_subagents"] = pending
                if not label:
                    label = f"Subagent · {fallback_task}" if fallback_task else "Subagent"
                active[sub_conv_id] = label
                changed = True
        else:
            if sub_conv_id in active:
                active.pop(sub_conv_id, None)
                changed = True

        if not changed:
            return

        parent_state["active_subagents"] = active
        save_state(parent_path, parent_state)

        parent_status = str(parent_state.get("status") or "")
        if parent_status not in ("run", "wait"):
            return

        parent_project = str(parent_state.get("project") or project)
        parent_bundle = str(parent_state.get("app_bundle") or app_bundle)
        parent_url = str(parent_state.get("action_url") or action_url)
        parent_pid = parent_state.get("pid") if isinstance(parent_state.get("pid"), int) else None
        parent_prompt = str(parent_state.get("prompt") or "")
        extra = subagent_extra_args(parent_state)
        if parent_prompt:
            extra.extend(["--prompt", parent_prompt])
        fire_async(
            build_notify_args(
                parent_project,
                "Working",
                parent_status,
                parent_sid,
                parent_bundle,
                action_url=parent_url,
                host_pid=parent_pid,
                extra=extra,
            )
        )


def handle_event(payload: dict[str, Any]) -> None:
    event = str(payload.get("hookEventName") or "")
    # Defer displaying a session until PreInvocation so empty/subagent sessions
    # never flash as top-level mascots on SessionStart.
    if event == "SessionStart":
        return

    conv_id = str(payload.get("conversationId") or "")
    host_pid = detect_host_pid()
    session_id = f"agy-{host_pid}" if host_pid else f"agy-{conv_id[:12] or os.getppid()}"
    root = workspace_root(payload)
    project = os.path.basename(root.rstrip("/")) if root else "Antigravity"
    app_bundle = detect_app_bundle(payload)
    action_url = detect_action_url(root, app_bundle)
    transcript = str(payload.get("transcriptPath") or "")

    prompt_raw = payload.get("lastUserInput")
    prompt_from_payload = one_line(prompt_raw, 160) if isinstance(prompt_raw, str) and prompt_raw.strip() else ""

    # Classify main agent vs subagent from transcript step 0.
    is_sub, parent_conv_id, sub_task = inspect_transcript_origin(transcript)
    if is_sub is None and not prompt_from_payload:
        # No user input and no USER_INPUT step in transcript -> treat as subagent/internal.
        return

    if is_sub is True:
        # Subagents live inside the same host `agy` process (same `session_id`);
        # fall back to parent's conversation ID only if host PID was unavailable.
        parent_sid = session_id if host_pid else (f"agy-{parent_conv_id[:12]}" if parent_conv_id else "")
        if parent_sid:
            update_parent_subagent(
                parent_sid=parent_sid,
                sub_conv_id=conv_id or transcript or "subagent",
                adding=(event != "Stop"),
                fallback_task=sub_task,
                project=project,
                app_bundle=app_bundle,
                action_url=action_url,
            )
        return

    st_path = state_file_path(session_id)
    now_ts = time.monotonic()

    with state_lock(st_path):
        state = load_state(st_path)
        prev_conv_id = str(state.get("conv_id") or "")
        # If the user started a new conversation (`/new`) in the same `agy` process,
        # reset stale prompt / subagent queues from the previous chat.
        if conv_id and prev_conv_id and conv_id != prev_conv_id:
            state["active_subagents"] = {}
            state["pending_subagents"] = []
            state["prompt"] = ""
        if conv_id:
            state["conv_id"] = conv_id

        prompt = prompt_from_payload or str(state.get("prompt") or "")

        if host_pid:
            state["pid"] = host_pid
        state["project"] = project
        if app_bundle:
            state["app_bundle"] = app_bundle
        if action_url:
            state["action_url"] = action_url

        def make(body: str, status: str, context_pct: int | None = None, extra: list[str] | None = None) -> list[str]:
            combined = list(subagent_extra_args(state))
            if extra:
                combined.extend(extra)
            return build_notify_args(
                project,
                body,
                status,
                session_id,
                app_bundle,
                action_url=action_url,
                host_pid=host_pid,
                context_pct=context_pct,
                extra=combined,
            )

        if event == "PreInvocation":
            prev_status = state.get("status")
            prev_prompt = state.get("prompt", "")
            if prev_status == "run" and prev_prompt == prompt and (now_ts - float(state.get("last_ts", 0))) < DETAIL_INTERVAL_S:
                return
            _, ctx_pct = transcript_metrics(transcript)
            state.update({"status": "run", "last_ts": now_ts, "prompt": prompt})
            save_state(st_path, state)
            extra = ["--prompt", prompt] if prompt else []
            fire_async(make("Working", "run", context_pct=ctx_pct, extra=extra))
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
                fire_async(make(q_text, "wait", extra=extra))
                return

            if tool == "invoke_subagent":
                role = one_line(str(args.get("Role") or args.get("TypeName") or "Subagent"), 60)
                sub_prompt = one_line(str(args.get("Prompt") or ""), 70)
                label = f"{role} · {sub_prompt}" if sub_prompt else role
                pending = state.get("pending_subagents")
                if not isinstance(pending, list):
                    pending = []
                pending.append(label)
                state["pending_subagents"] = pending[-20:]
                save_state(st_path, state)

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
            fire_async(make("Working", "run", extra=extra))
            return

        if event == "PostToolUse":
            tool_call = payload.get("toolCall") or {}
            if tool_call.get("name") == "ask_question":
                state.update({"status": "run", "last_ts": now_ts, "prompt": prompt})
                save_state(st_path, state)
                extra = ["--prompt", prompt] if prompt else []
                fire_async(make("Working", "run", extra=extra))
            return

        if event == "Stop":
            reason = str(payload.get("terminationReason") or "")
            error = str(payload.get("error") or "").strip()
            fully_idle = payload.get("fullyIdle")
            summary_text, ctx_pct = transcript_metrics(transcript)
            extra = ["--prompt", prompt] if prompt else []

            if fully_idle is False and reason not in ("ERROR", "USER_CANCELED") and not error:
                state.update({"status": "run", "last_ts": now_ts, "prompt": prompt})
                save_state(st_path, state)
                extra.extend(["--now", "Waiting on background tasks"])
                fire_async(make("Waiting on background tasks", "run", context_pct=ctx_pct, extra=extra))
                return

            # Turn finished: keep the mascot alive as `idle` (like omp) while the
            # `agy` process is open; `zzz.notch` reaps it automatically via `--pid`
            # once the `agy` terminal exits.
            state["active_subagents"] = {}
            state["pending_subagents"] = []
            state.update({"status": "idle", "last_ts": now_ts, "prompt": prompt})
            save_state(st_path, state)

            if reason == "ERROR" or error:
                msg = one_line(error or "Execution error", 140)
                fire_sequence_async(
                    make(msg, "fail", context_pct=ctx_pct, extra=extra),
                    make(msg, "idle", context_pct=ctx_pct, extra=extra),
                )
            elif reason == "USER_CANCELED":
                fire_async(make("Canceled", "idle", context_pct=ctx_pct, extra=extra))
            else:
                summary = summary_text or "Done"
                fire_sequence_async(
                    make(summary, "ok", context_pct=ctx_pct, extra=extra),
                    make(summary, "idle", context_pct=ctx_pct, extra=extra),
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
