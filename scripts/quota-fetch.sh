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

DIR="${ZAI_QUOTA_DIR:-$HOME/.claude/zaiquota}"
CACHE="$DIR/quota.cache"
MIN_INTERVAL=${ZAI_REFRESH_MIN:-600}

# ---- credentials ----
# config.env is READ, never sourced: plain KEY=VALUE lines only, so a tampered
# file cannot execute code next to the session environment. Environment
# variables take precedence (cron/launchd do not inherit them — hence the file).
CFG="$DIR/config.env"
cfg() { # $1=KEY -> value from config.env
  local line
  line=$(grep -E "^$1=" "$CFG" 2>/dev/null | tail -1) || return 0
  line=${line#*=}
  line=${line%$'\r'}
  case "$line" in   # tolerate one layer of matching quotes
    \"*\") line=${line#\"}; line=${line%\"} ;;
    \'*\') line=${line#\'}; line=${line%\'} ;;
  esac
  printf '%s' "$line"
}
if [ -e "$CFG" ]; then
  if [ ! -f "$CFG" ] || [ ! -O "$CFG" ]; then
    echo "ERROR: $CFG must be a regular file owned by you — refusing to read it" >&2
    exit 1
  fi
  chmod 600 "$CFG" 2>/dev/null || true   # self-heal overly wide permissions
fi
ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-$(cfg ANTHROPIC_AUTH_TOKEN)}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-$(cfg ANTHROPIC_BASE_URL)}"

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

# ---- credentials required ----
if [ -z "$ANTHROPIC_AUTH_TOKEN" ]; then
  echo "ERROR: ANTHROPIC_AUTH_TOKEN is not set (add it to $DIR/config.env)" >&2
  exit 1
fi
if [ -z "$ANTHROPIC_BASE_URL" ]; then
  echo "ERROR: ANTHROPIC_BASE_URL is not set (add it to $DIR/config.env)" >&2
  exit 1
fi

# ---- one GET to the plan-usage endpoint ----
domain=$(printf '%s' "$ANTHROPIC_BASE_URL" | sed -E 's|(https?://[^/]+).*|\1|')
case "$domain" in
  https://*) ;;
  http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;;
  *) echo "ERROR: ANTHROPIC_BASE_URL must be https:// — refusing to send the token in cleartext" >&2; exit 1 ;;
esac
url="${domain}/api/monitor/usage/quota/limit"

mkdir -p "$DIR"
tmp=$(mktemp "$DIR/.fetch.XXXXXX")   # unique per process: parallel fetches never collide
out=$(mktemp "$DIR/.fetch.XXXXXX")   # same directory as the cache: rename is atomic
trap 'rm -f "$tmp" "$out"' EXIT
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

# ---- validate the response shape BEFORE replacing a good cache ----
# A 200 with a junk body (proxy splash page, empty object) must not poison it.
if ! jq -e '(.data | type == "object") and (.data.limits | type == "array")' "$tmp" >/dev/null 2>&1; then
  echo "ERROR: unexpected response shape (no data.limits array) — cache left untouched" >&2
  head -c 2000 "$tmp" >&2
  echo >&2
  exit 1
fi

# ---- atomic cache update: fetch timestamp + the .data object ----
jq -c --argjson ts "$(date +%s)" '{fetched_at:$ts, data:.data}' "$tmp" > "$out"
mv -f "$out" "$CACHE"

[ "$FORCE" -eq 1 ] && echo "quota cache updated -> $CACHE"
exit 0
