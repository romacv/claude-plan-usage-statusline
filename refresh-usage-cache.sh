#!/bin/bash
# Refresh Claude usage cache in the background.
# Called by Claude Code Stop hook (async: true).
# Debounces to at most one API call per 900 seconds. Also honors a shared
# Retry-After backoff (/tmp/claude_usage_backoff) written by any caller that
# gets a 429, so this and statusline.rb never re-pin the rate-limit budget.
# A 429 is possible but is not the only way this can fail silently (e.g. a
# missing/invalid token), so every exit path leaves a one-line breadcrumb in
# /tmp/claude_usage_status (reason + local ISO-8601 timestamp, overwritten
# each run) via write_status() below.
#
# OAuth token resolution order (first non-empty wins):
#   1. $CLAUDE_CODE_OAUTH_TOKEN env var
#   2. Token file: $CLAUDE_USAGE_TOKEN_FILE, default
#      $HOME/.agents/keys/claude-oauth-token (set via `claude setup-token`)
#   3. macOS keychain item "Claude Code-credentials" ->
#      claudeAiOauth.accessToken (may not exist on newer Claude Code builds)
# If none yield a token, exit 0 without touching the cache (status: no_token).

CACHE_FILE="/tmp/claude_usage_cache.json"
LOCK_FILE="/tmp/claude_usage_refresh.lock"
BACKOFF_FILE="/tmp/claude_usage_backoff"
STATUS_FILE="/tmp/claude_usage_status"
MIN_INTERVAL=900

# Writes one line ("<reason> <local ISO-8601 timestamp>") to STATUS_FILE,
# overwriting it each time. Never the token, never the response body. Must
# never fail the script, so all errors are swallowed.
write_status() {
  { printf '%s %s\n' "$1" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$STATUS_FILE"; } 2>/dev/null
}

BACKOFF_UNTIL=$(cat "$BACKOFF_FILE" 2>/dev/null)
if [[ "$BACKOFF_UNTIL" =~ ^[0-9]+$ ]] && [ "$BACKOFF_UNTIL" -gt "$(date +%s)" ]; then
  write_status "backoff"
  exit 0
fi

if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
  if [ "$LOCK_AGE" -lt "$MIN_INTERVAL" ]; then
    write_status "debounced"
    exit 0
  fi
fi

touch "$LOCK_FILE"

TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"

if [ -z "$TOKEN" ]; then
  TOKEN_FILE="${CLAUDE_USAGE_TOKEN_FILE:-$HOME/.agents/keys/claude-oauth-token}"
  if [ -r "$TOKEN_FILE" ]; then
    TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE" 2>/dev/null)
  fi
fi

if [ -z "$TOKEN" ]; then
  CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [ -n "$CREDS" ]; then
    TOKEN=$(printf '%s' "$CREDS" | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("claudeAiOauth","accessToken")' 2>/dev/null)
  fi
fi

if [ -z "$TOKEN" ]; then
  write_status "no_token"
  exit 0
fi

HDR=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$HDR" "$BODY"' EXIT

HTTP_CODE=$(curl -s -D "$HDR" -o "$BODY" -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

if [ "$HTTP_CODE" = "429" ]; then
  RETRY_AFTER=$(tr -d '\r' < "$HDR" | grep -i '^retry-after:' | head -1 | sed 's/^[Rr]etry-[Aa]fter:[[:space:]]*//')
  [[ "$RETRY_AFTER" =~ ^[0-9]+$ ]] || RETRY_AFTER=3600
  echo "$(( $(date +%s) + RETRY_AFTER ))" > "$BACKOFF_FILE"
  write_status "http_429"
  exit 0
fi

if [ "$HTTP_CODE" != "200" ]; then
  write_status "http_${HTTP_CODE:-000}"
  exit 0
fi

# Only refresh when the payload is a usable usage reading. An error body
# (e.g. rate_limit_error) is valid JSON but must not clobber good cache.
if ruby -rjson -e '
resp = File.read(ARGV[0])
data = (JSON.parse(resp) rescue nil)
exit 1 if data.nil? || data["error"] || !data["five_hour"]
File.write(ARGV[1], resp)
File.delete(ARGV[2]) if File.exist?(ARGV[2])
' "$BODY" "$CACHE_FILE" "$BACKOFF_FILE" 2>/dev/null; then
  write_status "ok"
else
  write_status "bad_payload"
fi

exit 0
