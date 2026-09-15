#!/usr/bin/env bash
# Keep the stable path current: re-sync when the plugin's scripts have moved
# ahead of it.
#
#   ensure-current.sh   <- hooks.json, UserPromptSubmit and Stop, invoked via
#                          ${CLAUDE_PLUGIN_ROOT} so it always executes the NEW
#                          plugin's scripts after /plugin update
#
# SessionStart already syncs, but /plugin update and /reload-plugins never
# re-fire it — without this, a mid-session update left the stable copy stale
# until the next session start or a manual `bash scripts/sync.sh`. Chained
# before the stable-path quota-hook on the same events; the comparison is a
# handful of cmp calls and the entries are async, so prompts never wait on it.
#
# Best-effort by design: no set -e, sync failures swallowed, unconditional
# exit 0 — the quota hook chained after this one must always run (it stamps
# the .turn flag the statusline breath depends on). hook.log is append-only
# here (rotation stays quota-hook's job) and only after a SUCCESSFUL sync.
set -u
umask 077   # hook.log may be created here first — keep it user-private

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
DEST="${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}"
LOG="$DEST/hook.log"

stale=0
[ -d "$DEST" ] || stale=1
if [ "$stale" -eq 0 ]; then
  for f in "$SRC"/*.sh "$SRC"/jqsh; do
    [ -f "$f" ] || continue           # jqsh may be absent in a stripped tree
    name=$(basename "$f")
    cmp -s "$f" "$DEST/$name" || { stale=1; break; }   # missing counts as stale
  done
fi

[ "$stale" -eq 1 ] || exit 0

if "$SRC/sync.sh" >/dev/null 2>&1; then
  echo "$(date '+%F %T') sync: stable path resynced from plugin scripts" >>"$LOG" 2>/dev/null || :
  # Orphan report, once per resync: DEST *.sh the source tree no longer has.
  # Detection only — DEST may be a user-chosen directory (ZAI_QUOTA_DIR), so
  # nothing here ever deletes.
  for f in "$DEST"/*.sh; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    [ -f "$SRC/$name" ] || \
      echo "$(date '+%F %T') sync: orphan in stable path (not in plugin): $name" >>"$LOG" 2>/dev/null || :
  done
fi
exit 0
