#!/bin/bash
# Refresh Claude usage cache in the background.
# Called by Claude Code Stop hook (async: true).
# Debounces to at most one API call per 30 seconds.

CACHE_FILE="/tmp/claude_usage_cache.json"
LOCK_FILE="/tmp/claude_usage_refresh.lock"
MIN_INTERVAL=30

if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
  if [ "$LOCK_AGE" -lt "$MIN_INTERVAL" ]; then
    exit 0
  fi
fi

touch "$LOCK_FILE"

CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
[ -z "$CREDS" ] && exit 0

TOKEN=$(printf '%s' "$CREDS" | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("claudeAiOauth","accessToken")' 2>/dev/null)
[ -z "$TOKEN" ] && exit 0

RESPONSE=$(curl -s --max-time 10 \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
[ -z "$RESPONSE" ] && exit 0

printf '%s' "$RESPONSE" | ruby -rjson -e 'JSON.parse(STDIN.read)' 2>/dev/null || exit 0
printf '%s' "$RESPONSE" > "$CACHE_FILE"
