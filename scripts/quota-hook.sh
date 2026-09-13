#!/usr/bin/env bash
# Event hook — activity-driven quota refresh (no cron, no polling).
#
#   quota-hook.sh pre      <- UserPromptSubmit (prompt submitted)
#   quota-hook.sh post     <- Stop            (turn finished)
#   quota-hook.sh session  <- SessionStart    (startup/resume/clear)
#
# Registered in ~/.claude/settings.json with "async": true, so Claude Code runs
# it in the background and it never blocks prompt processing. An atomic
# mkdir-based lock guarantees at most one fetch at a time across ALL sessions,
# on every platform (flock is not available everywhere).
#
# Event-aware dedup window (ZAI_HOOK_DEDUP_SEC, default 8s):
#   - pre/session skip if ANY fetch happened within the window (a just-finished
#     turn's post already refreshed the cache);
#   - post is skipped only when the previous fetch was also a post (duplicate
#     Stop firing) — a turn consumes quota, so post always refreshes after pre;
#   - state is recorded BEFORE fetching: on network failure duplicates still
#     collapse instead of hammering a failing API.
set -u
umask 077   # log, lock and state files are user-private by default

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

# crude log rotation (wc -c is portable where GNU stat -c%s is not)
logsize=0
[ -f "$LOG" ] && logsize=$(wc -c <"$LOG")
[ "$logsize" -gt 262144 ] && : > "$LOG"

now=$(date +%s)

# cross-session single-fetch guarantee: mkdir is atomic on every platform.
# A timestamp inside the lock lets a crashed fetch's lock be reclaimed after
# 40s (2x the longest bounded fetch).
if [ -e "$LOCK" ] && [ ! -d "$LOCK" ]; then rm -f "$LOCK"; fi   # migrate old file lock
if ! mkdir "$LOCK" 2>/dev/null; then
  lockts=$(cat "$LOCK/ts" 2>/dev/null || echo 0)
  if [ $(( now - ${lockts:-0} )) -gt 40 ]; then
    rm -rf "$LOCK"
    if ! mkdir "$LOCK" 2>/dev/null; then
      echo "$(date '+%F %T') $EV skip: fetch already in flight" >>"$LOG"
      exit 0
    fi
  else
    echo "$(date '+%F %T') $EV skip: fetch already in flight" >>"$LOG"
    exit 0
  fi
fi
printf '%s\n' "$now" >"$LOCK/ts"
trap 'rm -rf "$LOCK"' EXIT   # release on every exit path once held

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
# timeout is GNU coreutils and absent on stock macOS; curl --max-time already
# bounds the network part, the wrapper is only extra insurance where it exists
fetch_failed=0
if command -v timeout >/dev/null 2>&1; then
  if ! timeout "${ZAI_HOOK_FETCH_TIMEOUT:-15}" "$SCRIPT_DIR/quota-fetch.sh" --force >>"$LOG" 2>&1; then
    fetch_failed=1
  fi
else
  if ! "$SCRIPT_DIR/quota-fetch.sh" --force >>"$LOG" 2>&1; then
    fetch_failed=1
  fi
fi
[ "$fetch_failed" -eq 1 ] && echo "$(date '+%F %T') $EV: fetch FAILED" >>"$LOG"
exit 0
