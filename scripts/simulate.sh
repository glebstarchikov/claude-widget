#!/bin/bash
# Replays a fake Claude Code session through the real hook binary.
# Usage: scripts/simulate.sh            full lifecycle (start → work → permission → work → stop → end)
#        scripts/simulate.sh finished   long-task Stop transition (tests the "Finished" peek)
#        scripts/simulate.sh approve [bash|multiline|edit|mcp]
#            one permission request through the real hook and the app's approval socket.
#            The hook's stdout (Claude Code's allow/deny JSON, or nothing) is passed
#            through unchanged; progress goes to stderr. The fake session claims to
#            belong to $OWNER (default com.apple.Terminal), so the app holds the
#            request only while that app isn't frontmost. Ends the session afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
HOOK=".build/debug/claude-widget-hook"
[ -x "$HOOK" ] || { echo "build first: swift build"; exit 1; }
STATE_DIR="$HOME/.claude/claude-widget/state"
SID="sim-$$"
CWD="$HOME/demo-project"

fire() { # fire <event> <extra-json-fields> <sleep-after>
  echo "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"$2}" | "$HOOK" "$1"
  echo "→ $1"
  sleep "$3"
}

if [ "${1:-}" = "finished" ]; then
  mkdir -p "$STATE_DIR"
  NOW=$(date +%s)
  SINCE=$((NOW - 120))
  cat > "$STATE_DIR/$SID.json" <<EOF
{"session_id":"$SID","state":"working","cwd":"$CWD","working_since":$SINCE,"updated_at":$NOW}
EOF
  echo "→ crafted 120 s working session"
  sleep 2
  fire Stop "" 6
  fire SessionEnd "" 0
  echo "done: you should have seen the Finished peek"
  exit 0
fi

if [ "${1:-}" = "approve" ]; then
  case "${2:-bash}" in
    bash)      TOOL=Bash; INPUT='{"command":"npm test","description":"Run the test suite"}' ;;
    multiline) TOOL=Bash; INPUT='{"command":"npm ci\nnpm run build\nnpm test"}' ;;
    edit)      TOOL=Edit; INPUT="{\"file_path\":\"$CWD/src/page.tsx\",\"old_string\":\"Hello\",\"new_string\":\"Hello, world\"}" ;;
    mcp)       TOOL=mcp__github__create_issue
               INPUT='{"repo":"glebstarchikov/demo-project","title":"Notch approvals: a long title that has to wrap onto a second line here","labels":["bug","ui"]}' ;;
    *) echo "unknown request kind: $2 (bash|multiline|edit|mcp)" >&2; exit 2 ;;
  esac
  OWNER="${OWNER:-com.apple.Terminal}"
  end_session() { echo "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}" | "$HOOK" SessionEnd; }
  trap end_session EXIT
  echo "→ PermissionRequest $TOOL (session $SID, owner $OWNER)" >&2
  START=$(date +%s)
  echo "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"tool_name\":\"$TOOL\",\"tool_input\":$INPUT}" \
    | __CFBundleIdentifier="$OWNER" "$HOOK" PermissionRequest
  echo "← hook exited after $(( $(date +%s) - START )) s" >&2
  exit 0
fi

fire SessionStart "" 2
fire UserPromptSubmit "" 4
fire PreToolUse ',"tool_name":"Bash"' 3
fire PermissionRequest ',"tool_name":"Bash"' 6
fire PreToolUse ',"tool_name":"Bash"' 4
fire Stop "" 5
fire SessionEnd "" 0
echo "done"
