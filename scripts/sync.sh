#!/usr/bin/env bash
# Install/sync the plugin scripts into the stable path, atomically.
#
# hooks.json runs this on SessionStart so plugin updates propagate, and the
# statusline/other hooks always execute from "$DEST". Files are copied to a
# process-unique temp name and renamed into place — a reader can never run a
# half-written script, and two sessions syncing at once never interleave.
set -eu

DEST="${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$SRC" ] || { echo "ERROR: source scripts not found at $SRC" >&2; exit 1; }
mkdir -p "$DEST"

for f in "$SRC"/*.sh "$SRC"/jqsh; do
  [ -f "$f" ] || continue           # jqsh may be absent in a stripped tree
  name=$(basename "$f")
  tmp="$DEST/.sync.$name.$$"        # process-unique: parallel syncs never collide
  cp -f "$f" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$DEST/$name"        # atomic rename within the same directory
done
