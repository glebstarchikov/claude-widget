#!/bin/bash
# Replays a fake Claude Code session through the real hook binary.
# Usage: scripts/simulate.sh            full lifecycle (start → work → permission → work → stop → end)
#        scripts/simulate.sh finished   long-task Stop transition (tests the "Finished" peek)
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

fire SessionStart "" 2
fire UserPromptSubmit "" 4
fire PreToolUse ',"tool_name":"Bash"' 3
fire PermissionRequest ',"tool_name":"Bash"' 6
fire PreToolUse ',"tool_name":"Bash"' 4
fire Stop "" 5
fire SessionEnd "" 0
echo "done"
