#!/usr/bin/env bash
# Event hook — activity-driven quota refresh (no cron, no polling).
#
#   quota-hook.sh pre      <- UserPromptSubmit (prompt submitted)
#   quota-hook.sh post     <- Stop            (turn finished)
#   quota-hook.sh session  <- SessionStart    (startup/resume/clear)
#
# Registered in ~/.claude/settings.json with "async": true, so Claude Code runs
# it in the background and it never blocks prompt processing. A PID-symlink
# lock (atomic claim + publication in one syscall) guarantees at most one
# fetch at a time across ALL sessions, on every platform.
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

DIR="${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# macOS ships no jq; the bundled jqsh (jq-subset interpreter) stands in.
command -v jq >/dev/null 2>&1 || \
  jq() { python3 "$SCRIPT_DIR/jqsh" "$@"; }
EV="${1:-pre}"
case "$EV" in pre|post|session) ;; *) exit 0 ;; esac

STATE="$DIR/.hook-state"
LOG="$DIR/hook.log"
WINDOW=${ZAI_HOOK_DEDUP_SEC:-8}

req=$(cat 2>/dev/null || true)   # hook stdin: tiny JSON (session_id is all we need)
mkdir -p "$DIR"

# crude log rotation (wc -c is portable where GNU stat -c%s is not)
logsize=0
[ -f "$LOG" ] && logsize=$(wc -c <"$LOG")
[ "$logsize" -gt 262144 ] && : > "$LOG"

now=$(date +%s)

# Turn-state flag for the statusline's dot pulse: `pre` stamps it at prompt
# submit, `post` clears it at turn end, `session` sweeps leftovers (a crashed
# turn must not leave an immortal pulse). Deliberately BEFORE the fetch
# lock/dedup below — pulse signaling must not depend on whether this hook's
# fetch runs; it is a file stamp, never an extra API call.
sid=$(jq -r '.session_id // empty' <<<"$req" 2>/dev/null)
case "$sid" in ''|*[!A-Za-z0-9_-]*) sid='' ;; esac   # filename-safe only
TURN="$DIR/.turn${sid:+-$sid}"
case "$EV" in
  pre)     printf '%s\n' "$now" >"$TURN" ;;
  post)    rm -f "$TURN" ;;          # own session only — a parallel one may still be busy
  session) rm -f "$DIR"/.turn* ;;    # fresh start sweeps stale flags from crashed turns
esac

# Cross-session single-fetch guarantee. The lock is a FIXED-NAME symlink
# whose target is the holder's PID: symlink(2) is atomic and publishes the
# PID in the same operation as the claim, so there is no claim/stamp window.
# A contender skips while the PID is alive and reclaims when it is gone.
# The pre-0.1.7 directory format (pid inside the dir) is still honored.
LOCK="$DIR/.fetch.lock"
holder=""
if [ -L "$LOCK" ]; then
  holder=$(readlink "$LOCK" 2>/dev/null)          # current format: target = PID
elif [ -d "$LOCK" ]; then
  holder=$(cat "$LOCK/pid" 2>/dev/null)           # legacy directory format
fi
if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
  echo "$(date '+%F %T') $EV skip: fetch already in flight" >>"$LOG"
  exit 0
fi
# no live holder: crashed claim, stale or legacy lock — reclaim and claim.
# ln -s is atomic; a competing claim simply fails, so this stays exclusive.
rm -rf "$LOCK"
if ! ln -s "$$" "$LOCK" 2>/dev/null; then
  echo "$(date '+%F %T') $EV skip: fetch already in flight" >>"$LOG"
  exit 0
fi
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
