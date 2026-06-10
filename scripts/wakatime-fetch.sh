#!/bin/bash
# WakaTime fetch — reliable time tracking for day-close
# Strategy: CLI for today, Neon fallback for yesterday (overnight sync)
# Usage: wakatime-fetch.sh [--yesterday|YYYY-MM-DD]

set -euo pipefail

TARGET="${1:---today}"

# === PHASE 1: Try WakaTime CLI (reliable, works for --today) ===
WAKATIME_CLI="${HOME}/.wakatime/wakatime-cli"
if [ "$TARGET" = "--today" ] || [ "$TARGET" = "today" ]; then
  if [ -f "$WAKATIME_CLI" ]; then
    RESULT=$("$WAKATIME_CLI" --today 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
      echo "$RESULT"
      exit 0
    fi
  fi
fi

# === PHASE 2: For --yesterday or specific date, fallback to Neon ===
# (WakaTime API token doesn't work, use database directly)

if [ "$TARGET" = "--yesterday" ] || [ "$TARGET" = "yesterday" ]; then
  TARGET_DATE=$(date -u -d "-1 day" "+%Y-%m-%d" 2>/dev/null || date -u -v-1d "+%Y-%m-%d")
else
  TARGET_DATE="$TARGET"
fi

# Placeholder for Neon fallback (requires DB access)
# Format: SELECT payload->>'human_readable' FROM learning.public.domain_event
# WHERE event_type='coding_time' AND account_id=... AND DATE(created_at)=TARGET_DATE

echo "⚠️  WakaTime data for $TARGET_DATE not available via CLI (overnight sync via Neon)"
echo "pending"
exit 1
