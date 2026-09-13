#!/usr/bin/env bash
# Event hook — activity-driven quota refresh (no cron, no polling).
#
#   quota-hook.sh pre      <- UserPromptSubmit (prompt submitted)
#   quota-hook.sh post     <- Stop            (turn finished)
#   quota-hook.sh session  <- SessionStart    (startup/resume/clear)
#
# Registered in ~/.claude/settings.json with "async": true, so Claude Code runs
# it in the background and it never blocks prompt processing. flock guarantees
# at most one fetch at a time across ALL sessions.
#
# Event-aware dedup window (ZAI_HOOK_DEDUP_SEC, default 8s):
#   - pre/session skip if ANY fetch happened within the window (a just-finished
#     turn's post already refreshed the cache);
#   - post is skipped only when the previous fetch was also a post (duplicate
#     Stop firing) — a turn consumes quota, so post always refreshes after pre;
#   - state is recorded BEFORE fetching: on network failure duplicates still
#     collapse instead of hammering a failing API.
set -u

DIR="$HOME/.claude/zaiquota"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EV="${1:-pre}"
case "$EV" in pre|post|session) ;; *) exit 0 ;; esac

STATE="$DIR/.hook-state"
LOCK="$DIR/.fetch.lock"
LOG="$DIR/hook.log"
WINDOW=${ZAI_HOOK_DEDUP_SEC:-8}

cat >/dev/null 2>&1 || true      # drain hook stdin (tiny JSON)
mkdir -p "$DIR"

# crude log rotation
if [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then : > "$LOG"; fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date '+%F %T') $EV skip: fetch already in flight" >>"$LOG"
  exit 0
fi

now=$(date +%s)
last=0 src=""
[ -f "$STATE" ] && IFS='|' read -r last src <"$STATE"
age=$(( now - last ))

skip=0
if [ "$age" -lt "$WINDOW" ]; then
  if [ "$EV" = "post" ]; then
    [ "$src" = "post" ] && skip=1
  else
    skip=1
  fi
fi

if [ "$skip" = 1 ]; then
  echo "$(date '+%F %T') $EV skip: dedup (last=$src ${age}s ago)" >>"$LOG"
  exit 0
fi

echo "$now|$EV" >"$STATE"
echo "$(date '+%F %T') $EV: force fetch" >>"$LOG"
if ! timeout "${ZAI_HOOK_FETCH_TIMEOUT:-15}" "$SCRIPT_DIR/quota-fetch.sh" --force >>"$LOG" 2>&1; then
  echo "$(date '+%F %T') $EV: fetch FAILED" >>"$LOG"
fi
exit 0
