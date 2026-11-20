#!/bin/bash
# Claude Code hook -> zzz.notch.
# Register this script for the Notification and Stop hook events. Notification
# ("Claude needs your permission / is waiting for input") stays on screen until
# answered or replaced; Stop replaces it with a short "done" event. One live
# event per session (id claude-<session_id>). Clicking it activates the
# terminal the session runs in. Never fails the hook.

zzz=${ZZZ_BIN:-$(command -v zzz || echo "$(cd "$(dirname "$0")/.." && pwd)/zzz")}
input=$(cat)
field() { printf '%s' "$input" | /usr/bin/jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null; }

event=$(field hook_event_name)
session=$(field session_id)
cwd=$(field cwd)
project=${cwd##*/}

case $event in
  Notification) status=wait; body=$(field message); body=${body:-Waiting for input}; duration=900 ;;
  Stop)         status=ok;   body=Done; duration=8 ;;
  *) exit 0 ;;
esac

"$zzz" notify "${project:-Claude Code}" "$body" \
  --source "Claude Code" --status "$status" --symbol sparkles \
  --app "${__CFBundleIdentifier:-}" --id "claude-${session:-default}" \
  --duration "$duration" >/dev/null 2>&1 || true
exit 0
