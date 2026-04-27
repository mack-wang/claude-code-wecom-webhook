#!/bin/bash
# Send WeCom notification for Stop and Notification events
set -euo pipefail

WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"
if [[ -z "$WEBHOOK_URL" ]]; then
  exit 0
fi

# ------------------------------------------------------------------
# 1. Read hook payload
# ------------------------------------------------------------------
HOOK_PAYLOAD=$(cat)

# Guard against non-JSON payload
if ! echo "$HOOK_PAYLOAD" | jq -e . > /dev/null 2>&1; then
  HOOK_PAYLOAD="{}"
fi

EVENT_NAME=$(echo "$HOOK_PAYLOAD" | jq -r '.hook_event_name // empty')
SESSION_ID=$(echo "$HOOK_PAYLOAD" | jq -r '.session_id // empty')
PID=$(echo "$HOOK_PAYLOAD" | jq -r '.pid // empty')

# ------------------------------------------------------------------
# 2. Resolve project name from payload / session file (not from current directory)
# ------------------------------------------------------------------
CWD=$(echo "$HOOK_PAYLOAD" | jq -r '.cwd // empty')

# Fallback: look up cwd from session file via session_id
if [[ -z "$CWD" && -n "$SESSION_ID" ]]; then
  SESSION_FILE=$(find "$HOME/.claude/sessions" -name "*.json" -maxdepth 1 -exec sh -c 'jq -e --arg sid "$1" ".sessionId == \$sid" "$2" >/dev/null 2>&1 && echo "$2"' _ "$SESSION_ID" {} \; 2>/dev/null | head -1)
  if [[ -n "$SESSION_FILE" ]]; then
    CWD=$(jq -r '.cwd // empty' "$SESSION_FILE" 2>/dev/null || true)
  fi
fi

if [[ -n "$CWD" ]]; then
  PROJECT=$(basename "$CWD")
else
  PROJECT=$(basename "$(pwd)")
fi

# ------------------------------------------------------------------
# 3. Resolve start time and compute duration
# ------------------------------------------------------------------
STARTED_AT=""
DURATION_STR="未知"

if [[ -n "$PID" && -f "$HOME/.claude/sessions/${PID}.json" ]]; then
  STARTED_AT=$(jq -r '.startedAt // empty' "$HOME/.claude/sessions/${PID}.json" 2>/dev/null || true)
fi

if [[ -z "$STARTED_AT" && -n "$SESSION_ID" ]]; then
  SESSION_FILE=$(find "$HOME/.claude/sessions" -name "*.json" -maxdepth 1 -exec sh -c 'jq -e --arg sid "$1" ".sessionId == \$sid" "$2" >/dev/null 2>&1 && echo "$2"' _ "$SESSION_ID" {} \; 2>/dev/null | head -1)
  if [[ -n "$SESSION_FILE" ]]; then
    STARTED_AT=$(jq -r '.startedAt // empty' "$SESSION_FILE" 2>/dev/null || true)
  fi
fi

if [[ -n "$STARTED_AT" ]]; then
  NOW_MS=$(date +%s000)
  DURATION_MS=$((NOW_MS - STARTED_AT))
  DURATION_SEC=$((DURATION_MS / 1000))
  if [[ $DURATION_SEC -lt 60 ]]; then
    DURATION_STR="${DURATION_SEC}秒"
  else
    DURATION_MIN=$((DURATION_SEC / 60))
    DURATION_REM=$((DURATION_SEC % 60))
    DURATION_STR="${DURATION_MIN}分${DURATION_REM}秒"
  fi
fi

# ------------------------------------------------------------------
# 4. Global dedup: any notification for this project within last 2min is skipped
# ------------------------------------------------------------------
GLOBAL_DEDUP_FILE="/tmp/claude-wecom-global-${PROJECT}"
if [[ -f "$GLOBAL_DEDUP_FILE" ]]; then
  LAST_SENT=$(cat "$GLOBAL_DEDUP_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [[ $((NOW - LAST_SENT)) -lt 120 ]]; then
    exit 0
  fi
fi

# ------------------------------------------------------------------
# 5. Resolve task summary
# ------------------------------------------------------------------
SUMMARY=""
NOTIFY_REASON=""
DEDUP_KEY=""

# 5a. Git commit — only check on Stop events, and run git in the correct directory
if [[ "$EVENT_NAME" == "Stop" ]]; then
  if [[ -n "$CWD" && -d "$CWD" ]]; then
    GIT_COMMIT_MSG=$(cd "$CWD" && git log -1 --since="10 minutes ago" --pretty=format:"%s" 2>/dev/null || true)
    GIT_COMMIT_HASH=$(cd "$CWD" && git log -1 --since="10 minutes ago" --pretty=format:"%H" 2>/dev/null || true)
  else
    GIT_COMMIT_MSG=$(git log -1 --since="10 minutes ago" --pretty=format:"%s" 2>/dev/null || true)
    GIT_COMMIT_HASH=$(git log -1 --since="10 minutes ago" --pretty=format:"%H" 2>/dev/null || true)
  fi
  if [[ -n "$GIT_COMMIT_MSG" && -n "$GIT_COMMIT_HASH" ]]; then
    SUMMARY="$GIT_COMMIT_MSG"
    NOTIFY_REASON="commit"
    DEDUP_KEY="commit-${GIT_COMMIT_HASH}"
  fi
fi

# 5b. Notification event — only notify if last_assistant_message indicates real user attention
if [[ -z "$NOTIFY_REASON" && "$EVENT_NAME" == "Notification" ]]; then
  LAST_MSG=$(echo "$HOOK_PAYLOAD" | jq -r '.last_assistant_message // empty')
  # Skip empty/dummy notifications (common after commits)
  if [[ -n "$LAST_MSG" && "$LAST_MSG" != "null" ]]; then
    SUMMARY="Claude Code 需要您的注意/授权，请查看终端"
    NOTIFY_REASON="notification"
    DEDUP_KEY="notification-${PROJECT}"
  fi
fi

# 5c. Stop event with pending tool_use in transcript
if [[ -z "$NOTIFY_REASON" && "$EVENT_NAME" == "Stop" ]]; then
  TRANSCRIPT_PATH=$(echo "$HOOK_PAYLOAD" | jq -r '.transcript_path // empty')
  if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    LAST_ENTRY=$(tail -1 "$TRANSCRIPT_PATH")
    LAST_TYPE=$(echo "$LAST_ENTRY" | jq -r '.type // empty')
    if [[ "$LAST_TYPE" == "assistant" ]]; then
      HAS_TOOL_USE=$(echo "$LAST_ENTRY" | jq 'if (.message.content | type) == "array" then (.message.content | any(.type == "tool_use")) else false end')
      if [[ "$HAS_TOOL_USE" == "true" ]]; then
        SUMMARY="Claude Code 等待授权/操作，请查看终端"
        NOTIFY_REASON="pending_tool"
        DEDUP_KEY="pending-tool-${PROJECT}"
      fi
    fi
  fi
fi

# Nothing to notify
if [[ -z "$NOTIFY_REASON" ]]; then
  exit 0
fi

# ------------------------------------------------------------------
# 6. Specific dedup
# ------------------------------------------------------------------
DEDUP_FILE="/tmp/claude-wecom-dedup-${DEDUP_KEY}"
if [[ -f "$DEDUP_FILE" ]]; then
  LAST_SENT=$(cat "$DEDUP_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [[ $((NOW - LAST_SENT)) -lt 300 ]]; then
    exit 0
  fi
fi

# ------------------------------------------------------------------
# 7. Build and send WeCom message
# ------------------------------------------------------------------
TIME=$(date '+%m-%d %H:%M:%S')

if [[ "$NOTIFY_REASON" == "commit" ]]; then
  TITLE_SUFFIX="任务完成 ✅"
else
  TITLE_SUFFIX="任务中断 🔴"
fi

MSG=$(jq -n \
  --arg project "$PROJECT" \
  --arg title_suffix "$TITLE_SUFFIX" \
  --arg time "$TIME" \
  --arg duration "$DURATION_STR" \
  --arg summary "$SUMMARY" \
  '{
    msgtype: "text",
    text: {
      content: "\($project)\($title_suffix)\n完成时间：\($time)\n执行用时：\($duration)\n任务总结：\($summary)"
    }
  }')

curl -s -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$MSG" \
  2>/dev/null || true

# Record dedup timestamps (do this early to prevent duplicate sends even if curl fails)
date +%s > "$DEDUP_FILE"
date +%s > "$GLOBAL_DEDUP_FILE"

# Cleanup marker file
if [[ -n "$SESSION_ID" && -f "/tmp/claude-start-${SESSION_ID}.ts" ]]; then
  rm -f "/tmp/claude-start-${SESSION_ID}.ts"
fi