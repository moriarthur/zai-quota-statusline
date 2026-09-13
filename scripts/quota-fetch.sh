#!/usr/bin/env bash
# Fetch the Z.AI coding-plan usage snapshot and cache it as JSON.
#
# Ban-safe by design: a single plain GET to the plan-usage endpoint with the
# same Authorization header Z.AI's own tooling sends — no retries, no quirks.
#
# Throttle: the network call is skipped while the cache is younger than
# ZAI_REFRESH_MIN seconds (default 600), so a frequent caller can never turn
# into polling. --force bypasses the throttle (manual refresh, event hooks
# that already implement their own dedup).
set -euo pipefail
umask 077   # cache and any temp files are user-private by default

DIR="$HOME/.claude/zaiquota"
CACHE="$DIR/quota.cache"
MIN_INTERVAL=${ZAI_REFRESH_MIN:-600}

# Credentials live in config.env (chmod 600) because cron/hooks don't inherit
# the interactive shell environment.
# shellcheck source=/dev/null
[ -f "$DIR/config.env" ] && . "$DIR/config.env"

FORCE=0
case "${1:-}" in -f|--force) FORCE=1 ;; esac

# ---- throttle (unless --force) ----
if [ "$FORCE" -eq 0 ] && [ -f "$CACHE" ]; then
  last=$(jq -r '.fetched_at // 0' "$CACHE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "${last:-0}" -gt 0 ] && [ $(( now - last )) -lt "$MIN_INTERVAL" ]; then
    exit 0   # cache is fresh enough — skip silently
  fi
fi

# ---- credentials ----
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  echo "ERROR: ANTHROPIC_AUTH_TOKEN is not set (add it to $DIR/config.env)" >&2
  exit 1
fi
if [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
  echo "ERROR: ANTHROPIC_BASE_URL is not set (add it to $DIR/config.env)" >&2
  exit 1
fi

# ---- one GET to the plan-usage endpoint ----
domain=$(printf '%s' "$ANTHROPIC_BASE_URL" | sed -E 's|(https?://[^/]+).*|\1|')
case "$domain" in
  https://*) ;;
  *) echo "ERROR: ANTHROPIC_BASE_URL must be https:// — refusing to send the token in cleartext" >&2; exit 1 ;;
esac
url="${domain}/api/monitor/usage/quota/limit"

mkdir -p "$DIR"
tmp=$(mktemp)
trap 'rm -f "$tmp" "${CACHE}.tmp"' EXIT   # no temp residue on any exit path
http=$(curl -sS -o "$tmp" -w '%{http_code}' \
  --max-time "${ZAI_FETCH_CURL_TIMEOUT:-20}" \
  -H "Authorization: ${ANTHROPIC_AUTH_TOKEN}" \
  -H "Accept-Language: en-US,en" \
  -H "Content-Type: application/json" \
  "$url") || { echo "ERROR: request failed" >&2; exit 1; }

if [ "$http" != "200" ]; then
  echo "ERROR: HTTP $http" >&2
  head -c 2000 "$tmp" >&2   # error body only, truncated
  echo >&2
  exit 1
fi

# ---- atomic cache update: fetch timestamp + the .data object ----
jq -c --argjson ts "$(date +%s)" '{fetched_at:$ts, data:.data}' "$tmp" > "${CACHE}.tmp" \
  && mv "${CACHE}.tmp" "$CACHE"

[ "$FORCE" -eq 1 ] && echo "quota cache updated -> $CACHE"
exit 0
