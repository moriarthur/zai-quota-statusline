#!/usr/bin/env bash
# Smoke tests — no network, no credentials. Run from anywhere: ./test.sh
# CI runs the same suite; every check prints ok/FAIL and the script exits 1 on any failure.
set -u
cd "$(dirname "$0")" || exit 1

pass=0 fail=0 skip=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
skipped() { printf 'skip %s\n' "$1"; skip=$((skip + 1)); }

strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

check() { # name expected-substring -- command...
  local name=$1 want=$2; shift 2
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  out=$(printf '%s' "$out" | strip_ansi)
  if [ "$rc" -ne 0 ]; then bad "$name (exit $rc)"; return; fi
  if [[ "$out" == *"$want"* ]]; then ok "$name"; else bad "$name — missing: $want"; fi
}

absent() { # name not-wanted-substring -- command...
  local name=$1 nw=$2; shift 2
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  out=$(printf '%s' "$out" | strip_ansi)
  if [ "$rc" -ne 0 ]; then bad "$name (exit $rc)"; return; fi
  if [[ "$out" != *"$nw"* ]]; then ok "$name"; else bad "$name — unexpectedly contains: $nw"; fi
}

# ---- syntax + manifests ----
for f in scripts/*.sh test.sh; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done
for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if jq empty "$j" 2>/dev/null; then ok "jq $j"; else bad "jq $j"; fi
done
# the marketplace manifest repeats the plugin version — the two have drifted
# apart before (marketplace said 0.1.20 through two releases); pin them together
if command -v jq >/dev/null 2>&1; then
  pv=$(jq -r '.version' .claude-plugin/plugin.json 2>/dev/null)
  mv=$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json 2>/dev/null)
  if [ -n "$pv" ] && [ "$pv" = "$mv" ]; then
    ok "manifests: marketplace version tracks plugin.json ($pv)"
  else
    bad "manifests: marketplace version ($mv) != plugin.json ($pv)"
  fi
fi
if shellcheck scripts/*.sh test.sh 2>/dev/null; then
  ok "shellcheck"
elif command -v shellcheck >/dev/null; then
  bad "shellcheck"
else
  skipped "shellcheck (not installed)"
fi

# ---- statusline fixtures ----
NOW=$(date +%s)
FIX=$(mktemp)
jq -n --argjson ts "$NOW" --argjson a 9 --argjson b 77 \
  --argjson ra "$(( (NOW + 10800) * 1000 ))" --argjson rb "$(( (NOW + 172800) * 1000 ))" \
  '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:$a,nextResetTime:$ra},{type:"TOKENS_LIMIT",percentage:$b,nextResetTime:$rb}]}}' > "$FIX"

# `sb` only ever runs through check/absent's "$@" indirection, which shellcheck
# cannot see; shellcheck >=0.9 flags the definition as unreachable (0.8.0, our
# pinned dev version, predates that check). Silence the false positive.
# shellcheck disable=SC2317
# renders get an isolated ZAI_QUOTA_DIR: hysteresis state must never land in (or
# read from) the dev machine's live ~/.claude/zaiquota
TEST_SB_DIR=$(mktemp -d)
sb() { printf '%s' "$1" | env ZAI_QUOTA_DIR="$TEST_SB_DIR" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh; }

IN='{"model":{"display_name":"glm-5.3-flash[1m]"},"context_window":{"used_percentage":62},"cost":{"total_cost_usd":5.1}}'
check "statusline: exact model (1M marker stripped)" "GLM-5.3-Flash" sb "$IN"
check "statusline: context-left from used%"         "context left 38%" sb "$IN"
check "statusline: session cost"                    "\$5.10"           sb "$IN"
absent "statusline: non-numeric cost hides the segment" '$' \
  env ZAI_QUOTA_DIR="$TEST_SB_DIR" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh \
  <<< '{"model":{"display_name":"X"},"cost":{"total_cost_usd":"abc"}}'
absent "statusline: negative cost hides the segment" '$' \
  env ZAI_QUOTA_DIR="$TEST_SB_DIR" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh \
  <<< '{"model":{"display_name":"X"},"cost":{"total_cost_usd":-1.2}}'
check "statusline: scientific-notation cost renders" "\$0.00" \
  env ZAI_QUOTA_DIR="$TEST_SB_DIR" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh \
  <<< '{"model":{"display_name":"X"},"cost":{"total_cost_usd":1e-05}}'
check "statusline: 5h/7d segments"                  "7d"               sb "$IN"
check "statusline: tier resolved via env mapping"   "GLM-5.3-Flash"    env ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3-flash ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< '{"model":{"display_name":"Sonnet 4.5"}}'
# an isolated ZAI_QUOTA_DIR keeps the missing-cache self-heal out of these two:
# with the dev machine's real config.env present, an absent cache would spawn a
# live fetch from the suite
EMPTY=$(mktemp -d)
check "statusline: empty stdin falls back"          "Claude"           env ZAI_QUOTA_DIR="$EMPTY" ZAI_SB_CACHE=/tmp/zai-ci-nope bash scripts/zai-statusline.sh </dev/null
check "statusline: no cache is quiet"               "quota n/a"        env ZAI_QUOTA_DIR="$EMPTY" ZAI_SB_CACHE=/tmp/zai-ci-nope bash scripts/zai-statusline.sh </dev/null
rm -rf "$EMPTY"
PILL_CAP=$(printf '\ue0b6')   # the retired Nerd Font pill cap (U+E0B6), ASCII escape so the glyph never travels through edits
absent "statusline: chip is plain everywhere (no pill caps)" "$PILL_CAP" \
  env ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"
absent "statusline: pill background SGR left with the pill" $'\033[48;5;236' \
  env ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"
MAC_DOT=$(printf '\u25cf')
check  "statusline: plain status dot renders" "$MAC_DOT" \
  env ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"

# ---- jqsh: without jq on PATH the statusline must render identically ----
# macOS has no jq; the bundled jqsh (python3) substitutes. Stripping jq from
# PATH exercises the fallback end-to-end: same cache, same stdin, same line.
if command -v python3 >/dev/null 2>&1; then
  NOPATH=$(mktemp -d)
  for t in bash sh cat uname date sed tr cut head dirname python3 env mktemp chmod rm grep; do
    # type -P: PATH-resolved EXECUTABLE only — `command -v` can return a shell
    # function's bare name (this session had grep wrapped), producing a symlink
    # that points at itself
    p=$(type -P "$t" 2>/dev/null) && ln -s "$p" "$NOPATH/$t"
  done
  # remaining-time tokens ("3h 0m") are masked before comparing: the two renders
  # can straddle a minute boundary, which changes the string but not the parser
  plain=$(printf '%s' "$IN" | env ZAI_QUOTA_DIR="$TEST_SB_DIR" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh \
    | sed -E 's/[0-9]+d [0-9]+h/T/g; s/[0-9]+h [0-9]+m/T/g; s/[0-9]+m/T/g')
  shimmed=$(printf '%s' "$IN" | env PATH="$NOPATH" ZAI_QUOTA_DIR="$TEST_SB_DIR" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh \
    | sed -E 's/[0-9]+d [0-9]+h/T/g; s/[0-9]+h [0-9]+m/T/g; s/[0-9]+m/T/g')
  if [ -n "$plain" ] && [ "$plain" = "$shimmed" ]; then
    ok "statusline: jqsh fallback renders the identical line"
  else
    bad "statusline: jqsh fallback renders the identical line"
  fi
  rm -rf "$NOPATH"
else
  skipped "statusline: jqsh fallback (python3 missing)"
fi
rm -rf "$TEST_SB_DIR"

# ---- jqsh: every filter the scripts use must produce jq-identical output ----
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if python3 -m py_compile scripts/jqsh 2>/dev/null; then
    ok "jqsh: compiles"
  else
    bad "jqsh: compiles"
  fi
  SF=$(mktemp)
  printf '%s' '{"fetched_at":1726000000,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":42,"number":5,"unit":1,"nextResetTime":1726003600000},{"type":"TOKENS_LIMIT","percentage":77,"number":7,"unit":3,"nextResetTime":1727300000000},{"type":"CREDIT_LIMIT","percentage":9,"nextResetTime":1}]}}' > "$SF"
  # the verbatim cache query from zai-statusline.sh ($l/$tok/... are jq vars,
  # not shell ones — hence SC2016)
  # shellcheck disable=SC2016
  TSV='(.data.limits // []) as $l
      | ([$l[] | select(.type == "TOKENS_LIMIT")] | sort_by(.nextResetTime)) as $tok
      | (if ($tok | length) > 0 then $tok
         else [$l[] | select(.type == "CREDIT_LIMIT")] | sort_by(.nextResetTime)
         end) as $t
      | (if ($tok | length) == 2
           and ($t[0].number != null) and ($t[1].number != null)
           and $t[0].number != $t[1].number
           and (($t[0].number == 5) or ($t[1].number == 5))
         then (if $t[0].number == 5 then $t else [$t[1], $t[0]] end)
         else $t end) as $o
      | [ (($o[0].percentage // 0) | floor),
          ((($o[0].nextResetTime // 0) / 1000) | floor),
          (($o[1].percentage // 0) | floor),
          ((($o[1].nextResetTime // 0) / 1000) | floor),
          (.fetched_at // 0),
          (if ($tok | length) > 0 then "w" else "c" end) ]
      | @tsv'
  cmpjq() { # name -- jq args...  (compare stdout and exit code: jq vs jqsh)
    local name=$1; shift
    local a b ra rb
    a=$(jq "$@" 2>/dev/null); ra=$?
    b=$(python3 scripts/jqsh "$@" 2>/dev/null); rb=$?
    if [ "$a" = "$b" ] && [ "$ra" = "$rb" ]; then ok "jqsh: $name"
    else bad "jqsh: $name (jq rc=$ra, shim rc=$rb)"; fi
  }
  cmpjq "throttle timestamp"   -r '.fetched_at // 0' "$SF"
  cmpjq "response shape (-e)"  -e '(.data | type == "object") and (.data.limits | type == "array")' "$SF"
  # the $ts/$k single-quoted strings are jq variables, deliberately not shell's
  # shellcheck disable=SC2016
  cmpjq "cache transform (-c)" -c --argjson ts 1726000010 '{fetched_at:$ts, data:.data}' "$SF"
  # shellcheck disable=SC2016
  cmpjq "env tier lookup"      -r --arg k ANTHROPIC_DEFAULT_SONNET_MODEL '.env[$k] // empty' "$SF"
  cmpjq "model name chain"     -r '.model.display_name // .model.id // empty' "$SF"
  cmpjq "quota TSV query"      -r "$TSV" "$SF"
  cmpjq "session id"           -r '.session_id // empty' "$SF"
  cmpjq "context used"         -r '.context_window.used_percentage // empty' "$SF"
  cmpjq "context remaining"    -r '.context_window.remaining_percentage // empty' "$SF"
  cmpjq "session cost"         -r '.cost.total_cost_usd // empty' "$SF"
  printf '%s' '{"fetched_at":5,"data":{"limits":[{"type":"CREDIT_LIMIT","percentage":13,"nextResetTime":99}]}}' > "$SF"
  cmpjq "TSV: credit-only plan" -r "$TSV" "$SF"
  printf '%s' '{"fetched_at":5,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":10,"number":7,"nextResetTime":1000},{"type":"TOKENS_LIMIT","percentage":90,"number":5,"nextResetTime":500}]}}' > "$SF"
  cmpjq "TSV: number-labeled swap" -r "$TSV" "$SF"
  printf '%s' '{"fetched_at":5,"data":{}}' > "$SF"
  cmpjq "TSV: no limits array" -r "$TSV" "$SF"
  rm -f "$SF"
else
  skipped "jqsh parity (needs jq and python3)"
fi
printf '%s' '{"model":{"display_name":"X"},"context_window":{"used_percentage":"abc"},"cost":"1..2"}' \
  | env ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh >/tmp/zai_ci_out 2>/tmp/zai_ci_err
if ! grep -qE 'integer expression|invalid number' /tmp/zai_ci_err 2>/dev/null; then
  ok "statusline: numeric garbage stays silent"
else
  bad "statusline: numeric garbage stays silent"
fi
rm -f "$FIX" /tmp/zai_ci_out /tmp/zai_ci_err

# ---- sync: atomic install into the stable path ----
TH=$(mktemp -d)
if ZAI_QUOTA_DIR="$TH/zq" bash scripts/sync.sh >/dev/null 2>&1 \
  && [ -x "$TH/zq/quota-fetch.sh" ] && [ -x "$TH/zq/quota-hook.sh" ] \
  && [ -x "$TH/zq/zai-statusline.sh" ] && [ -x "$TH/zq/sync.sh" ] \
  && [ -x "$TH/zq/ensure-current.sh" ] && [ -x "$TH/zq/jqsh" ]; then
  ok "sync: installs all scripts executable"
else
  bad "sync: installs all scripts executable"
fi
rm -rf "$TH"

# ---- ensure-current: re-syncs the stable path when the plugin moves ahead ----
# the hook chain runs this from ${CLAUDE_PLUGIN_ROOT} before every quota hook,
# so a mid-session /plugin update propagates without a session restart.
# parity(): "mismatch" when any source file is missing from or differs in DEST
parity() { # <dest> <src>
  local d=$1 s=$2 f stale=0
  for f in "$s"/*.sh "$s"/jqsh; do
    [ -f "$f" ] || continue
    cmp -s "$f" "$d/$(basename "$f")" || stale=1
  done
  [ "$stale" -eq 0 ] || echo mismatch
}
TH=$(mktemp -d)
ZAI_QUOTA_DIR="$TH/zq" bash scripts/sync.sh >/dev/null 2>&1
rc=0
ZAI_QUOTA_DIR="$TH/zq" bash scripts/ensure-current.sh >/dev/null 2>&1 || rc=1
if [ "$rc" -eq 0 ] && [ -z "$(parity "$TH/zq" scripts)" ] && [ ! -e "$TH/zq/hook.log" ]; then
  ok "ensure-current: in-sync run touches nothing, no log line"
else
  bad "ensure-current: in-sync run touches nothing, no log line"
fi
rm -rf "$TH"

TH=$(mktemp -d)
ZAI_QUOTA_DIR="$TH/zq" bash scripts/sync.sh >/dev/null 2>&1
printf '#!/usr/bin/env bash\n# stale pre-0.1.14 pill build\n' >"$TH/zq/zai-statusline.sh"
rc=0
ZAI_QUOTA_DIR="$TH/zq" bash scripts/ensure-current.sh >/dev/null 2>&1 || rc=1
if [ "$rc" -eq 0 ] && [ -z "$(parity "$TH/zq" scripts)" ] && [ -x "$TH/zq/jqsh" ] \
  && grep -q "sync: stable path resynced" "$TH/zq/hook.log" 2>/dev/null; then
  ok "ensure-current: stale DEST fully resyncs and logs"
else
  bad "ensure-current: stale DEST fully resyncs and logs"
fi
rm -rf "$TH"

TH=$(mktemp -d)
rc=0
ZAI_QUOTA_DIR="$TH/zq" bash scripts/ensure-current.sh >/dev/null 2>&1 || rc=1
allok=1
for f in quota-fetch.sh quota-hook.sh zai-statusline.sh sync.sh ensure-current.sh jqsh; do
  [ -x "$TH/zq/$f" ] || allok=0
done
if [ "$rc" -eq 0 ] && [ "$allok" -eq 1 ]; then
  ok "ensure-current: missing DEST installs all 6 files executable"
else
  bad "ensure-current: missing DEST installs all 6 files executable"
fi
rm -rf "$TH"

TH=$(mktemp -d)
: >"$TH/zq"   # DEST as a regular file: sync's mkdir -p fails for root and non-root alike
rc=0
ZAI_QUOTA_DIR="$TH/zq" bash scripts/ensure-current.sh >/dev/null 2>&1 || rc=1
if [ "$rc" -eq 0 ]; then
  ok "ensure-current: failed sync stays best-effort (exit 0)"
else
  bad "ensure-current: failed sync stays best-effort (exit 0)"
fi
rm -rf "$TH"

# ---- ZAI_QUOTA_DIR: advertised in README, so the wiring must honor it ----
# a hardcoded stable path in an entry point silently splits code (installed
# dir) from data (default dir) and the statusline shows "quota n/a"
FIX3=$(mktemp -d)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:42,nextResetTime:(($ts+3600)*1000)}]}}' > "$FIX3/quota.cache"
out=$(printf '%s' "$IN" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIX3" bash scripts/zai-statusline.sh 2>&1 | strip_ansi)
if [[ "$out" == *"42%"* ]]; then
  ok "statusline: ZAI_QUOTA_DIR resolves the cache"
else
  bad "statusline: ZAI_QUOTA_DIR resolves the cache"
fi
rm -rf "$FIX3"

# ---- CLAUDE_CONFIG_DIR: relocating the whole Claude config moves the base dir ----
# default chain: ZAI_QUOTA_DIR > $CLAUDE_CONFIG_DIR/zaiquota > ~/.claude/zaiquota
FIX5=$(mktemp -d); mkdir -p "$FIX5/zaiquota"
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:7,nextResetTime:(($ts+3600)*1000)}]}}' > "$FIX5/zaiquota/quota.cache"
out=$(printf '%s' "$IN" | env -u ZAI_SB_CACHE -u ZAI_QUOTA_DIR CLAUDE_CONFIG_DIR="$FIX5" bash scripts/zai-statusline.sh 2>&1 | strip_ansi)
if [[ "$out" == *"7%"* ]]; then
  ok "statusline: CLAUDE_CONFIG_DIR resolves the cache"
else
  bad "statusline: CLAUDE_CONFIG_DIR resolves the cache"
fi
FIX6=$(mktemp -d)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:13,nextResetTime:(($ts+3600)*1000)}]}}' > "$FIX6/quota.cache"
out=$(printf '%s' "$IN" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIX6" CLAUDE_CONFIG_DIR="$FIX5" bash scripts/zai-statusline.sh 2>&1 | strip_ansi)
if [[ "$out" == *"13%"* ]]; then
  ok "statusline: ZAI_QUOTA_DIR overrides CLAUDE_CONFIG_DIR"
else
  bad "statusline: ZAI_QUOTA_DIR overrides CLAUDE_CONFIG_DIR"
fi
rm -rf "$FIX5" "$FIX6"

# ---- statusline: the dot breathes between the dim gray and the tier tone ----
# Two tones: the hueless gray "off" end (240) and the tier color — gray, tone,
# gray, tone, one second a tone, toggling every beat (the host render floor:
# refreshInterval min 1 s), no SGR faint (an attribute render paths drop).
# Checks read RAW output
# (the suite's ANSI-stripper would erase the very thing under test); 21% usage
# = green tier = mid 65 — which the quota bar carries on every frame, so the
# breath phases are distinguished by the 240 code the breath alone emits.
# ZAI_SB_TEST_TICK freezes the clock in whole seconds.
FIXD=$(mktemp -d)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:21,nextResetTime:(($ts+3600)*1000)}]}}' > "$FIXD/quota.cache"
printf '%s\n' "$NOW" > "$FIXD/.turn"
low=$'\033[38;5;65m'; dim=$'\033[38;5;240m'; oldpeak=$'\033[38;5;151m'; faint=$'\033[2;38;5;'
sb_tick() { printf '%s' "$IN" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK="$1" bash scripts/zai-statusline.sh; }
raw=$(sb_tick 0)
if [[ "$raw" == *"$dim"* ]]; then
  ok "statusline: breath phase 0 is the dim gray"
else
  bad "statusline: breath phase 0 is the dim gray"
fi
raw=$(sb_tick 1)
if [[ "$raw" == *"$low"* && "$raw" != *"$dim"* ]]; then
  ok "statusline: breath phase 1 is the mid tier tone"
else
  bad "statusline: breath phase 1 is the mid tier tone"
fi
raw=$(sb_tick 2)
if [[ "$raw" == *"$dim"* && "$raw" != *"$oldpeak"* && "$raw" != *"$faint"* ]]; then
  ok "statusline: breath phase 2 is the dim gray again (old bright step and SGR faint gone)"
else
  bad "statusline: breath phase 2 is the dim gray again (old bright step and SGR faint gone)"
fi
raw=$(sb_tick 3)
if [[ "$raw" == *"$low"* && "$raw" != *"$dim"* ]]; then
  ok "statusline: breath phase 3 is the mid tier tone"
else
  bad "statusline: breath phase 3 is the mid tier tone"
fi
rm -f "$FIXD/.turn"   # idle case: the breath tests above left their flag behind
raw=$(sb_tick 0)
if [[ "$raw" != *"$dim"* ]]; then
  ok "statusline: idle dot is static (no turn flag)"
else
  bad "statusline: idle dot is static (no turn flag)"
fi
printf '0\n' > "$FIXD/.turn"   # stamp older than the 24h sanity cap
raw=$(sb_tick 0)
if [[ "$raw" != *"$dim"* ]]; then
  ok "statusline: stale turn flag does not breathe"
else
  bad "statusline: stale turn flag does not breathe"
fi
# per-session flag: only the owning session breathes (checked at the gray
# phase, tick 0 — the only tone whose presence is unambiguous)
IN_SID='{"model":{"display_name":"X"},"session_id":"sb-pulse-test"}'
printf '%s\n' "$NOW" > "$FIXD/.turn-sb-pulse-test"
raw=$(printf '%s' "$IN_SID" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=0 bash scripts/zai-statusline.sh)
if [[ "$raw" == *"$dim"* ]]; then
  ok "statusline: session-scoped turn flag breathes its own session"
else
  bad "statusline: session-scoped turn flag breathes its own session"
fi
rm -f "$FIXD/.turn-sb-pulse-test"
raw=$(printf '%s' "$IN_SID" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=0 bash scripts/zai-statusline.sh)
if [[ "$raw" != *"$dim"* ]]; then
  ok "statusline: another session's flag does not breathe this one"
else
  bad "statusline: another session's flag does not breathe this one"
fi

# ---- statusline: context-left hysteresis over sequential frames ----
# The CC statusline payload can carry a transient zero-sum usage object (used_
# percentage:0 → remaining=100). A real reading never rounds to used=0 (the
# context would have to sit under half a percent of the window — below the
# system-prompt floor), so a literal 100 is the placeholder and is never
# rendered at all: an existing shown value
# is held (fresh or stale state), and before the first real frame the segment
# stays hidden. Other rises of >=10 points display only after they repeat on
# two CONSECUTIVE identical frames; falls show at once. Each scenario drives
# real sequential renders through one session's state file.
HY=$(mktemp -d)
hys_seq() { # $@ = used_percentage per frame -> printed "context left N%" per line
  for u in "$@"; do
    v=$(printf '{"model":{"display_name":"X"},"session_id":"sb-hyst","context_window":{"used_percentage":%s}}' "$u" \
      | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$HY" ZAI_SB_TEST_TICK=7 ZAI_SB_DEBUG="${ZAI_SB_DEBUG:-0}" \
        bash scripts/zai-statusline.sh 2>&1 \
      | strip_ansi | sed -E 's/.*context left ([0-9]+)%.*/\1/; t; s/.*/-/')
    printf '%s\n' "$v"   # the statusline emits no trailing newline — add one
  done
}   # a frame with no context segment prints "-"
res=$(hys_seq 11 0 12)
if [ "$res" = $'89\n89\n88' ]; then
  ok "hysteresis: 89→100→88 shows 89→89→88 (phantom held, fall at once)"
else
  bad "hysteresis: 89→100→88 shows 89→89→88 (phantom held, fall at once)"
fi
rm -f "$HY/.ctx-sb-hyst"
res=$(hys_seq 11 0 0)
if [ "$res" = $'89\n89\n89' ]; then
  ok "hysteresis: a 100 placeholder never confirms over a shown value"
else
  bad "hysteresis: a 100 placeholder never confirms over a shown value"
fi
rm -f "$HY/.ctx-sb-hyst"
res=$(hys_seq 11 0 0 0 0 0)
if [ "$res" = $'89\n89\n89\n89\n89\n89' ]; then
  ok "hysteresis: a placeholder lasting 5 frames (the live ~5 s report) never shows 100"
else
  bad "hysteresis: a placeholder lasting 5 frames (the live ~5 s report) never shows 100"
fi
rm -f "$HY/.ctx-sb-hyst"
res=$(hys_seq 50 0 0 20 20)
if [ "$res" = $'50\n50\n50\n50\n80' ]; then
  ok "hysteresis: after a /clear the next real frames confirm the new figure (100 skipped)"
else
  bad "hysteresis: after a /clear the next real frames confirm the new figure (100 skipped)"
fi
rm -f "$HY/.ctx-sb-hyst"
res=$(hys_seq 11 0 3 3)
if [ "$res" = $'89\n89\n97\n97' ]; then
  ok "hysteresis: 97 after 89 is a small rise — shows at once (100 placeholder ignored)"
else
  bad "hysteresis: 97 after 89 is a small rise — shows at once (100 placeholder ignored)"
fi
rm -f "$HY/.ctx-sb-hyst"
res=$(hys_seq 11 30)
if [ "$res" = $'89\n70' ]; then
  ok "hysteresis: falls show at once (89→70)"
else
  bad "hysteresis: falls show at once (89→70)"
fi
rm -f "$HY/.ctx-sb-hyst"
res=$(hys_seq 0 0)
if [ "$res" = $'-\n-' ] && [ ! -f "$HY/.ctx-sb-hyst" ]; then
  ok "hysteresis: fresh 100 is the session-start placeholder — hidden, no state seeded"
else
  bad "hysteresis: fresh 100 is the session-start placeholder — hidden, no state seeded"
fi
res=$(hys_seq 11 0)
if [ "$res" = $'89\n89' ] && [ -f "$HY/.ctx-sb-hyst" ]; then
  ok "hysteresis: first real frame shows and seeds state; the next placeholder holds it"
else
  bad "hysteresis: first real frame shows and seeds state; the next placeholder holds it"
fi
printf '89|0|0|%s\n' "$(( NOW - 400 ))" >"$HY/.ctx-sb-hyst"
res=$(hys_seq 0)
if [ "$res" = "89" ]; then
  ok "hysteresis: stale state still holds through the placeholder (100 is never resurrected)"
else
  bad "hysteresis: stale state still holds through the placeholder (100 is never resurrected)"
fi
printf '100|0|0|%s\n' "$NOW" >"$HY/.ctx-sb-hyst"
res=$(hys_seq 0)
if [ "$res" = "-" ] && [ "$(cat "$HY/.ctx-sb-hyst")" = "100|0|0|$NOW" ]; then
  ok "hysteresis: shown=100 state is pre-fix residue — not held, not rewritten"
else
  bad "hysteresis: shown=100 state is pre-fix residue — not held, not rewritten"
fi

# ---- statusline: ZAI_SB_DEBUG logs incidents only ----
rm -f "$HY/statusline-debug.log" "$HY/.ctx-sb-hyst"
ZAI_SB_DEBUG=1 hys_seq 11 >/dev/null   # first frame: raw==shown, no previous — silent
ZAI_SB_DEBUG=1 hys_seq 0  >/dev/null   # held jump: raw=100 shown=89
ZAI_SB_DEBUG=1 hys_seq 12 >/dev/null   # accepted change: shown 88 != previous 89
if [ "$(wc -l <"$HY/statusline-debug.log" 2>/dev/null)" = "2" ]; then
  ok "debug: hold and change log a line each, first frame stays silent"
else
  bad "debug: hold and change log a line each, first frame stays silent"
fi
if grep -q "used=0|remaining=100|shown=89|held=1" "$HY/statusline-debug.log" 2>/dev/null; then
  ok "debug: the held line carries raw, shown and the held flag"
else
  bad "debug: the held line carries raw, shown and the held flag"
fi
if [ -n "$(find "$HY" -name statusline-debug.log -perm 0600)" ]; then
  ok "debug: log is user-private (0600)"
else
  bad "debug: log is user-private (0600)"
fi
ZAI_SB_DEBUG=1 hys_seq 12 >/dev/null   # steady repeat: same value, nothing to log
if [ "$(wc -l <"$HY/statusline-debug.log")" = "2" ]; then
  ok "debug: steady renders write nothing"
else
  bad "debug: steady renders write nothing"
fi
# the atomic state write must not leave temp files behind
hys_seq 5 >/dev/null                   # an accepted change — one state write
if [ "$(find "$HY" -name '.ctx*' | wc -l)" = "1" ]; then
  ok "hysteresis: atomic state write leaves exactly the state file, no temps"
else
  bad "hysteresis: atomic state write leaves exactly the state file, no temps"
fi
rm -rf "$HY"
rm -rf "$FIXD"

# ---- hook: pre stamps the turn flag, post clears it ----
TH=$(mktemp -d)
printf '{"session_id":"pulse-hook-test"}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1
if [ -f "$TH/.claude/zaiquota/.turn-pulse-hook-test" ]; then
  ok "hook: pre stamps the per-session turn flag"
else
  bad "hook: pre stamps the per-session turn flag"
fi
printf '{"session_id":"pulse-hook-test"}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh post >/dev/null 2>&1
if [ ! -f "$TH/.claude/zaiquota/.turn-pulse-hook-test" ]; then
  ok "hook: post clears the turn flag"
else
  bad "hook: post clears the turn flag"
fi
rm -rf "$TH"
# guard: every path INTO the stable dir in the wiring must resolve through the
# full fallback chain — ZAI_QUOTA_DIR, then CLAUDE_CONFIG_DIR, then ~/.claude.
# A bare joined path would silently split code (installed dir) from data and
# the statusline would show "quota n/a"
# the chain is a literal for grep -F, never expanded here:
# shellcheck disable=SC2016
CHAIN='${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}'
chainmiss=""
for spec in "hooks/hooks.json 3" "commands/refresh.md 2" "scripts/zai-statusline.sh 1" \
            "scripts/sync.sh 1" "scripts/ensure-current.sh 1" \
            "scripts/quota-fetch.sh 1" "scripts/quota-hook.sh 1"; do
  f=${spec% *}; want=${spec#* }
  [ "$(grep -cF -- "$CHAIN" "$f")" = "$want" ] || chainmiss="$chainmiss $f"
done
if [ -n "$chainmiss" ]; then
  bad "wiring: fallback chain wrong in:$chainmiss"
else
  ok "wiring: every entry point resolves through the full fallback chain"
fi

# ---- statusline: window labels follow number, not reset order ----
# the 7-day window (number=7) resets SOONER than the 5-hour one: labels must
# still read 5h first, 7d second
TDIR=$(mktemp -d)   # isolated ZAI_QUOTA_DIR: hysteresis state must not touch the live dir
FIX2=$(mktemp)
jq -n --argjson ts "$NOW"   '{fetched_at:$ts, data:{limits:[
     {type:"TOKENS_LIMIT",percentage:10,number:7,unit:3,nextResetTime:(($ts+3600)*1000)},
     {type:"TOKENS_LIMIT",percentage:90,number:5,unit:1,nextResetTime:(($ts+172800)*1000)}]}}' > "$FIX2"
out=$(printf '%s' "$IN" | env ZAI_QUOTA_DIR="$TDIR" ZAI_SB_CACHE="$FIX2" bash scripts/zai-statusline.sh 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')
if [[ "$out" == *'5h'*'90%'*'7d'* ]]; then
  ok "statusline: labels follow window number, not reset order"
else
  bad "statusline: labels follow window number, not reset order"
fi
rm -f "$FIX2"

# ---- statusline: remaining time separates unit groups ----
# regression: "2h45m"/"1d4h" read as one glued token; expect "2h 45m"/"1d 4h".
# offsets carry +30s so a second or two of test drift never crosses a boundary
FIX4=$(mktemp)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[
     {type:"TOKENS_LIMIT",percentage:30,number:5,unit:1,nextResetTime:(($ts+9930)*1000)},
     {type:"TOKENS_LIMIT",percentage:60,number:7,unit:3,nextResetTime:(($ts+104130)*1000)}]}}' > "$FIX4"
out=$(printf '%s' "$IN" | env ZAI_QUOTA_DIR="$TDIR" ZAI_SB_CACHE="$FIX4" bash scripts/zai-statusline.sh 2>&1 | strip_ansi)
if [[ "$out" == *"2h 45m"* && "$out" == *"1d 4h"* ]]; then
  ok "statusline: remaining time separates units (\"2h 45m\", \"1d 4h\")"
else
  bad "statusline: remaining time separates units (\"2h 45m\", \"1d 4h\")"
fi
rm -f "$FIX4"

# ---- statusline: credit-only plans render bare reset-sorted bars ----
# since 2026-09-15 Z.AI ships the plan windows as CREDIT_LIMIT (the old
# TOKENS_LIMIT data), and the credit number/unit fields do not map to window
# durations — so both bars render bare, reset-sorted, with no invented labels
FIX5=$(mktemp)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[{type:"CREDIT_LIMIT",percentage:37,nextResetTime:(($ts+7200)*1000)}]}}' > "$FIX5"
out=$(printf '%s' "$IN" | env ZAI_QUOTA_DIR="$TDIR" ZAI_SB_CACHE="$FIX5" bash scripts/zai-statusline.sh 2>&1 | strip_ansi)
if [[ "$out" == *'37%'* ]] && [[ "$out" != *'5h'* ]] && [[ "$out" != *'7d'* ]] && [[ "$out" != *'quota'* ]]; then
  ok "statusline: credit-only plan is a bare bar (no invented labels)"
else
  bad "statusline: credit-only plan is a bare bar (no invented labels)"
fi
rm -f "$FIX5"
FIX6=$(mktemp)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[
     {type:"CREDIT_LIMIT",number:5,unit:3,percentage:35,nextResetTime:(($ts+4800)*1000)},
     {type:"CREDIT_LIMIT",number:1,unit:6,percentage:10,nextResetTime:(($ts+525600)*1000)}]}}' > "$FIX6"
out=$(printf '%s' "$IN" | env ZAI_QUOTA_DIR="$TDIR" ZAI_SB_CACHE="$FIX6" bash scripts/zai-statusline.sh 2>&1 | strip_ansi)
if [[ "$out" == *'5h'*'35%'*'7d'*'10%'* ]]; then
  ok "statusline: live Z.AI credit payload keeps the 5h/7d labels (renamed token windows)"
else
  bad "statusline: live Z.AI credit payload keeps the 5h/7d labels (renamed token windows)"
fi
rm -f "$FIX6"
rm -rf "$TDIR"

# ---- statusline: a passed reset time nudges one throttled refresh ----
# the hooks refresh on prompts and turn ends only, so a window that rolls over
# between turns must self-heal on the next render instead of freezing the old
# bars at "99% ... 0m". Tokens are stripped so the spawned --force fetch can
# never touch the network from the suite.
TH=$(mktemp -d)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[
     {type:"TOKENS_LIMIT",percentage:99,number:5,unit:1,nextResetTime:(($ts-60000)*1000)},
     {type:"TOKENS_LIMIT",percentage:77,number:7,unit:3,nextResetTime:(($ts+172800)*1000)}]}}' > "$TH/quota.cache"
run_sb() { # $1=ZAI_QUOTA_DIR — render one statusline into the void
  printf '%s' "$IN" | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_SB_CACHE \
    ZAI_QUOTA_DIR="$1" bash scripts/zai-statusline.sh >/dev/null 2>&1
}
run_sb "$TH"
if [ -f "$TH/.rollrefresh" ]; then
  ok "rollover: an expired reset time stamps a refresh nudge"
else
  bad "rollover: an expired reset time stamps a refresh nudge"
fi
s1=$(cat "$TH/.rollrefresh" 2>/dev/null)
run_sb "$TH"
s2=$(cat "$TH/.rollrefresh" 2>/dev/null)
if [ -n "$s1" ] && [ "$s1" = "$s2" ]; then
  ok "rollover: re-renders within the minute do not re-nudge"
else
  bad "rollover: re-renders within the minute do not re-nudge"
fi
mkdir -p "$TH/future"
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:9,nextResetTime:(($ts+10800)*1000)}]}}' > "$TH/future/quota.cache"
run_sb "$TH/future"
if [ ! -f "$TH/future/.rollrefresh" ]; then
  ok "rollover: future resets stay quiet"
else
  bad "rollover: future resets stay quiet"
fi
rm -rf "$TH"

# ---- statusline: no usable windows + config.env nudges one throttled fetch ----
# If the session hook never ran (killed, missed install), the first render sees
# no cache at all; and a cache whose payload parses to ZERO windows (an unparsable
# body, or the observed 2026-09-15 shape-valid `limits: []` mid-swap) renders n/a
# forever on its own. Both mean only a fresh fetch can fix the render: with
# credentials on disk they nudge one background --force fetch (same stamp/throttle
# as the rollover nudge — a permanently empty shape costs one GET per minute, not
# a loop); an install with no discoverable credentials never spawns. config.env points at a
# closed loopback port, so the spawned fetch fails instantly and never touches
# the network from the suite.
NH=$(mktemp -d)
printf 'ANTHROPIC_AUTH_TOKEN=dummy-test-token\nANTHROPIC_BASE_URL=http://127.0.0.1:1\n' >"$NH/config.env"
run_sb "$NH"
if [ -f "$NH/.rollrefresh" ]; then
  ok "self-heal: missing cache with config.env nudges one fetch"
else
  bad "self-heal: missing cache with config.env nudges one fetch"
fi
n1=$(cat "$NH/.rollrefresh" 2>/dev/null)
run_sb "$NH"
n2=$(cat "$NH/.rollrefresh" 2>/dev/null)
if [ -n "$n1" ] && [ "$n1" = "$n2" ]; then
  ok "self-heal: re-renders within the minute do not re-nudge"
else
  bad "self-heal: re-renders within the minute do not re-nudge"
fi
NH2=$(mktemp -d)
run_sb "$NH2"
if [ ! -f "$NH2/.rollrefresh" ]; then
  ok "self-heal: no credentials at all stay quiet"
else
  bad "self-heal: no credentials at all stay quiet"
fi
NH3=$(mktemp -d)
printf 'not json at all' >"$NH3/quota.cache"
printf 'ANTHROPIC_AUTH_TOKEN=dummy-test-token\nANTHROPIC_BASE_URL=http://127.0.0.1:1\n' >"$NH3/config.env"
run_sb "$NH3"
if [ -f "$NH3/.rollrefresh" ]; then
  ok "self-heal: an unparsable cache nudges (zero windows can't heal alone)"
else
  bad "self-heal: an unparsable cache nudges (zero windows can't heal alone)"
fi
p1=$(cat "$NH3/.rollrefresh" 2>/dev/null)
run_sb "$NH3"
p2=$(cat "$NH3/.rollrefresh" 2>/dev/null)
if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then
  ok "self-heal: window-less re-renders within the minute do not re-nudge"
else
  bad "self-heal: window-less re-renders within the minute do not re-nudge"
fi
NH4=$(mktemp -d)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[]}}' >"$NH4/quota.cache"
run_sb "$NH4"
if [ ! -f "$NH4/.rollrefresh" ]; then
  ok "self-heal: shape-valid but empty cache stays quiet without credentials"
else
  bad "self-heal: shape-valid but empty cache stays quiet without credentials"
fi
NH5=$(mktemp -d)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[]}}' >"$NH5/quota.cache"
printf 'ANTHROPIC_AUTH_TOKEN=dummy-test-token\nANTHROPIC_BASE_URL=http://127.0.0.1:1\n' >"$NH5/config.env"
run_sb "$NH5"
if [ -f "$NH5/.rollrefresh" ]; then
  ok "self-heal: a shape-valid empty cache nudges (the 0.1.16-era poison)"
else
  bad "self-heal: a shape-valid empty cache nudges (the 0.1.16-era poison)"
fi
# env-only install (0.1.22): credentials in the environment alone arm the
# self-heal exactly like a config.env on disk — the gate must follow the
# fetcher's own resolution order (env first, file fallback). The dead loopback
# URL keeps any spawned fetch off the network.
NHE=$(mktemp -d)
printf '%s' "$IN" | env -u CLAUDE_CONFIG_DIR -u ZAI_SB_CACHE \
  ANTHROPIC_AUTH_TOKEN=dummy-test-token ANTHROPIC_BASE_URL=http://127.0.0.1:1 \
  ZAI_QUOTA_DIR="$NHE" bash scripts/zai-statusline.sh >/dev/null 2>&1
if [ -f "$NHE/.rollrefresh" ]; then
  ok "self-heal: env-only credentials (no config.env) arm the nudge"
else
  bad "self-heal: env-only credentials (no config.env) arm the nudge"
fi
rm -rf "$NHE"
rm -rf "$NH" "$NH2" "$NH3" "$NH4" "$NH5"

# ---- statusline: the nudge claim is atomic across parallel renders ----
# two Claude windows on one project render concurrently; a PID-symlink claim
# (same idiom as the fetch lock) must let exactly one of them spawn the fetch
NHL=$(mktemp -d)
printf 'ANTHROPIC_AUTH_TOKEN=dummy-test-token\nANTHROPIC_BASE_URL=http://127.0.0.1:1\n' >"$NHL/config.env"
ln -s "$$" "$NHL/.rollrefresh.lock"   # a live sibling render — this shell — holds the claim
run_sb "$NHL"
if [ ! -f "$NHL/.rollrefresh" ]; then
  ok "self-heal: a live sibling claim defers the nudge"
else
  bad "self-heal: a live sibling claim defers the nudge"
fi
rm -f "$NHL/.rollrefresh.lock"
run_sb "$NHL"
if [ -f "$NHL/.rollrefresh" ]; then
  ok "self-heal: a free claim nudges normally"
else
  bad "self-heal: a free claim nudges normally"
fi
# a hook fetch in flight writes the cache itself — the nudge defers to it,
# keeping a cold start at one fetch instead of two
ln -s "$$" "$NHL/.fetch.lock"
rm -f "$NHL/.rollrefresh"
run_sb "$NHL"
if [ ! -f "$NHL/.rollrefresh" ]; then
  ok "self-heal: an in-flight hook fetch defers the nudge"
else
  bad "self-heal: an in-flight hook fetch defers the nudge"
fi
rm -f "$NHL/.fetch.lock"
run_sb "$NHL"
if [ -f "$NHL/.rollrefresh" ]; then
  ok "self-heal: with the hook done, the nudge fires again"
else
  bad "self-heal: with the hook done, the nudge fires again"
fi
# the nudge routes its fetch through the hook wrapper: lock, dedup and
# hook.log visibility all come along (bounded wait for the background spawn)
NHH=$(mktemp -d)
printf 'ANTHROPIC_AUTH_TOKEN=dummy-test-token\nANTHROPIC_BASE_URL=http://127.0.0.1:1\n' >"$NHH/config.env"
run_sb "$NHH"
n=0
while [ "$n" -lt 30 ] && ! grep -q "session: force fetch" "$NHH/hook.log" 2>/dev/null; do
  sleep 0.1; n=$((n + 1))
done
if grep -q "session: force fetch" "$NHH/hook.log" 2>/dev/null; then
  ok "self-heal: the nudge fetch goes through the hook wrapper"
else
  bad "self-heal: the nudge fetch goes through the hook wrapper"
fi
rm -rf "$NHH"

ESC=$(printf '\033')
# \033[2J on purpose: the suite's ANSI-stripper only masks m-terminated SGR
# codes, so a clear-screen escape in the output would still be detected
absent "statusline: mapping values sanitized (no ANSI)" "$ESC" \
  env ANTHROPIC_DEFAULT_SONNET_MODEL=$'EVIL\033[2JGLM-9' ZAI_SB_CACHE=/tmp/zai-ci-nope \
  bash scripts/zai-statusline.sh <<< '{"model":{"display_name":"Sonnet 4.5"}}'

# ---- hook: session sweep spares live parallel sessions ----
# a new session must not wipe another live session's pulse flag or hysteresis
# state; only genuinely stale files (older than the readers' own caps) go
TH=$(mktemp -d)
mkdir -p "$TH/.claude/zaiquota"
printf '%s\n' "$NOW" >"$TH/.claude/zaiquota/.turn-live"
printf '50|0|0|%s\n' "$NOW" >"$TH/.claude/zaiquota/.ctx-live"
printf '%s\n' "$(( NOW - 90000 ))" >"$TH/.claude/zaiquota/.turn-dead"
printf '50|0|0|%s\n' "$(( NOW - 90000 ))" >"$TH/.claude/zaiquota/.ctx-dead"
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR \
  HOME="$TH" bash scripts/quota-hook.sh session >/dev/null 2>&1
if [ -f "$TH/.claude/zaiquota/.turn-live" ] && [ -f "$TH/.claude/zaiquota/.ctx-live" ] \
   && [ ! -f "$TH/.claude/zaiquota/.turn-dead" ] && [ ! -f "$TH/.claude/zaiquota/.ctx-dead" ]; then
  ok "hook: session sweep removes stale state, keeps live parallel sessions"
else
  bad "hook: session sweep removes stale state, keeps live parallel sessions"
fi
rm -rf "$TH"

# ---- hook: isolated HOME, no credentials -> logs the attempt, still exit 0 ----
# (env -u strips any inherited ANTHROPIC_* so the test never touches the network)
TH=$(mktemp -d)
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q "pre: force fetch" "$TH/.claude/zaiquota/hook.log" 2>/dev/null; then
  ok "hook: pre fires and logs (exit 0)"
else
  bad "hook: pre fires and logs (exit $rc)"
fi
if grep -q "fetch FAILED" "$TH/.claude/zaiquota/hook.log" 2>/dev/null; then
  ok "hook: fetch failure is logged, not fatal"
else
  bad "hook: fetch failure is logged, not fatal"
fi
rm -rf "$TH"

# ---- hook: the lock actually excludes (PID-symlink format) ----
# live holder (current symlink format) -> contender skips without fetching
TH=$(mktemp -d); mkdir -p "$TH/.claude/zaiquota"
sleep 30 & HOLDER=$!
ln -s "$HOLDER" "$TH/.claude/zaiquota/.fetch.lock"
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1
if ! grep -q "force fetch" "$TH/.claude/zaiquota/hook.log" 2>/dev/null \
  && grep -q "skip: fetch already in flight" "$TH/.claude/zaiquota/hook.log" 2>/dev/null; then
  ok "hook: live lock skips the fetch"
else
  bad "hook: live lock skips the fetch"
fi
kill "$HOLDER" 2>/dev/null; rm -rf "$TH"

# live holder (pre-0.1.7 directory format) -> still honored, contender skips
TH=$(mktemp -d); mkdir -p "$TH/.claude/zaiquota/.fetch.lock"
sleep 30 & HOLDER=$!
printf '%s\n' "$HOLDER" > "$TH/.claude/zaiquota/.fetch.lock/pid"
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1
if ! grep -q "force fetch" "$TH/.claude/zaiquota/hook.log" 2>/dev/null \
  && grep -q "skip: fetch already in flight" "$TH/.claude/zaiquota/hook.log" 2>/dev/null; then
  ok "hook: legacy dir lock is still honored"
else
  bad "hook: legacy dir lock is still honored"
fi
kill "$HOLDER" 2>/dev/null; rm -rf "$TH"

# dead holder -> contender reclaims and fetches
TH=$(mktemp -d); mkdir -p "$TH/.claude/zaiquota"
sleep 0.2 & DEAD=$!
wait "$DEAD" 2>/dev/null   # a PID that certainly has no live process
ln -s "$DEAD" "$TH/.claude/zaiquota/.fetch.lock"
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1
if grep -q "force fetch" "$TH/.claude/zaiquota/hook.log" 2>/dev/null; then
  ok "hook: dead lock is reclaimed and the fetch runs"
else
  bad "hook: dead lock is reclaimed and the fetch runs"
fi
rm -rf "$TH"

# concurrent starts -> exactly one fetch
TH=$(mktemp -d); mkdir -p "$TH/.claude/zaiquota"
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1 &
P1=$!
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1 &
P2=$!
wait "$P1" "$P2"
n=$(grep -c "force fetch" "$TH/.claude/zaiquota/hook.log" 2>/dev/null || true)
n=${n:-0}
if [ "$n" = "1" ]; then
  ok "hook: concurrent starts fetch exactly once"
else
  bad "hook: concurrent starts fetch exactly once (n=$n)"
fi
rm -rf "$TH"

# ---- fetcher: missing credentials fail loudly ----
TH=$(mktemp -d)
out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"ANTHROPIC_AUTH_TOKEN"* ]]; then
  ok "fetcher: missing token fails with a clear message"
else
  bad "fetcher: missing token fails with a clear message (exit $rc)"
fi
rm -rf "$TH"

# ---- fetcher: neither jq nor python3 -> an actionable error, no network ----
TH=$(mktemp -d)
NOPATH=$(mktemp -d)
for t in bash env curl; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOPATH/$t"
done
out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR PATH="$NOPATH" HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"jq (or python3) is required"* ]]; then
  ok "fetcher: no jq and no python3 fails with a fix, not a parse error"
else
  bad "fetcher: no jq and no python3 fails with a fix, not a parse error (exit $rc)"
fi
rm -rf "$TH" "$NOPATH"

# ---- security: the token never travels further than the configured host ----
# env -u strips real credentials so the tests never touch the live API
# wiring guard: the token must ride in a stdin-fed curl header (-H @-), never as
# a curl argument — an argv value is readable in the process list (ps) for the
# life of the request. grep -F: the pattern is shell-literal, not a regex.
# the grep pattern is intentionally a literal (SC2016) — that's the source text being guarded
# shellcheck disable=SC2016
if grep -qF -- '-H @-' scripts/quota-fetch.sh \
   && ! grep -qF 'Authorization: ${ANTHROPIC_AUTH_TOKEN}' scripts/quota-fetch.sh; then
  ok "security: token fed to curl via stdin, not argv (invisible to ps)"
else
  bad "security: token fed to curl via stdin, not argv (invisible to ps)"
fi
# runtime proof (vs the source-level guard above): a fake curl records its argv
# and stdin — argv is exactly what ps would see — and serves canned responses.
# Run 1: healthy 200 → the token appears only in stdin, the cache is written.
# Run 2: a 401 whose body ECHOES the token back → the log must show [REDACTED].
FAKEPATH=$(mktemp -d)
for t in bash sh cat uname date sed tr cut head tail dirname python3 env mktemp mkdir chmod rm grep jq awk mv sleep; do
  # type -P, not command -v: same self-symlink trap as the jqsh loop above
  p=$(type -P "$t" 2>/dev/null) && ln -s "$p" "$FAKEPATH/$t"
done
cat > "$FAKEPATH/curl" <<'SHIM'
#!/usr/bin/env bash
# test shim: records argv+stdin, serves $FAKE_CODE with $FAKE_BODY
cap="$FAKE_CAP"
{ printf 'ARGS\n'; printf '%s\n' "$@"; printf 'STDIN\n'; cat; } > "$cap"
out=''; prev=''
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev=$a
done
[ -n "$out" ] && printf '%s' "$FAKE_BODY" > "$out"
printf '%s' "$FAKE_CODE"
SHIM
chmod +x "$FAKEPATH/curl"
FDIR=$(mktemp -d)
mkdir -p "$FDIR/.claude/zaiquota"
printf 'ANTHROPIC_BASE_URL=https://127.0.0.1:1/api/anthropic\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' > "$FDIR/.claude/zaiquota/config.env"
run_fakesb() { # $1=http code $2=body — fetch through the shim, capture output
  FAKE_CAP="$FDIR/cap" FAKE_CODE="$1" FAKE_BODY="$2" \
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR \
    PATH="$FAKEPATH" HOME="$FDIR" bash scripts/quota-fetch.sh --force 2>&1
}
BODY='{"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":5,"nextResetTime":99999999999999}]}}'
out=$(run_fakesb 200 "$BODY"); rc=$?
args=$(sed -n '/^ARGS$/,/^STDIN$/p' "$FDIR/cap")
stdin=$(sed -n '/^STDIN$/,$p' "$FDIR/cap" | tail -n +2)
if [ "$rc" -eq 0 ] && [[ "$stdin" == *"Authorization: DUMMY_TOKEN_VALUE"* ]] \
   && ! [[ "$args" == *"DUMMY_TOKEN_VALUE"* ]] \
   && grep -qx -- '-q' <<<"$args" && grep -qx -- '-H' <<<"$args" && grep -qx -- '@-' <<<"$args" \
   && jq -e '.data.limits[0].percentage == 5' "$FDIR/.claude/zaiquota/quota.cache" >/dev/null 2>&1; then
  ok "security: runtime — token rides only in stdin, never in curl argv (what ps sees)"
else
  bad "security: runtime — token rides only in stdin, never in curl argv (exit $rc)"
fi
out=$(run_fakesb 401 '{"error":"echo DUMMY_TOKEN_VALUE back"}'); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *'[REDACTED]'* ]] && [[ "$out" != *"DUMMY_TOKEN_VALUE"* ]]; then
  ok "security: runtime — a hostile error body echoing the token is redacted before logging"
else
  bad "security: runtime — a hostile error body echoing the token is redacted before logging (exit $rc)"
fi
rm -rf "$FAKEPATH" "$FDIR"
TH=$(mktemp -d)
mkdir -p "$TH/.claude/zaiquota"
printf 'ANTHROPIC_BASE_URL=https://127.0.0.1:1/api/anthropic\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' > "$TH/.claude/zaiquota/config.env"
out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" != *"DUMMY_TOKEN_VALUE"* ]]; then
  ok "security: failed fetch never echoes the token"
else
  bad "security: failed fetch never echoes the token (exit $rc)"
fi
printf 'ANTHROPIC_BASE_URL=http://insecure.example.com/api/anthropic\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' > "$TH/.claude/zaiquota/config.env"
out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"https://"* ]] && [[ "$out" != *"DUMMY_TOKEN_VALUE"* ]]; then
  ok "security: plain-http base URL is refused"
else
  bad "security: plain-http base URL is refused (exit $rc)"
fi
rm -rf "$TH"

# ---- security: a junk HTTP 200 must not poison a good cache ----
# loopback http is allowed by the fetcher precisely so this is testable offline.
# The server must serve the fetcher's real endpoint path, else we'd test a 404.
if command -v python3 >/dev/null 2>&1; then
  TH=$(mktemp -d); mkdir -p "$TH/.claude/zaiquota" "$TH/srv/api/monitor/usage/quota"
  ENDPOINT="$TH/srv/api/monitor/usage/quota/limit"
  ( cd "$TH/srv" && exec python3 -u -m http.server 0 >"$TH/srv/err" 2>&1 ) &
  SRVPID=$!
  PORT=''
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    PORT=$(grep -oE 'port [0-9]+' "$TH/srv/err" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ -n "$PORT" ] && break
  done
  if [ -z "$PORT" ]; then
    # the environment cannot bind a test server (sandbox/CI restriction) —
    # this is environmental, not a defect; skip rather than fail. ALL FOUR
    # server-fed checks skip together: the tally must always sum to the total
    # (a vanished check once made a reviewer's 107+1 look like a miscount).
    skipped "junk-200 (test server could not bind)"
    skipped "valid 200 writes a 0600 cache (test server could not bind)"
    skipped "empty limits leaves a good cache untouched (test server could not bind)"
    skipped "empty limits with no cache seeds nothing (test server could not bind)"
  else
    printf '{"data":null}' > "$ENDPOINT"   # 200 with a junk body
    printf 'ANTHROPIC_BASE_URL=http://127.0.0.1:%s\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' "$PORT" > "$TH/.claude/zaiquota/config.env"
    out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [ ! -f "$TH/.claude/zaiquota/quota.cache" ] && [[ "$out" == *"unexpected response shape"* ]]; then
      ok "security: junk 200 leaves the cache untouched"
    else
      bad "security: junk 200 leaves the cache untouched (rc=$rc)"
    fi
    printf '{"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":9,"nextResetTime":123}]}}' > "$ENDPOINT"   # a valid 200
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force >/dev/null 2>&1
    cacheperm=$(stat -c %a "$TH/.claude/zaiquota/quota.cache" 2>/dev/null || stat -f %Lp "$TH/.claude/zaiquota/quota.cache" 2>/dev/null)
    if [ -f "$TH/.claude/zaiquota/quota.cache" ] && [ "$cacheperm" = "600" ]; then
      ok "security: valid 200 writes a 0600 cache"
    else
      bad "security: valid 200 writes a 0600 cache (perm=$cacheperm)"
    fi
    # ---- empty limits is a transient snapshot: rendered as nothing, so it is
    # never stored — not over a good cache, and not as a fake-looking empty one
    printf '{"data":{"limits":[]}}' > "$ENDPOINT"
    printf '{"fetched_at":1,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":42,"nextResetTime":9}]}}' > "$TH/.claude/zaiquota/quota.cache"
    out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *"empty limits"* ]] \
      && [ "$(cat "$TH/.claude/zaiquota/quota.cache")" = '{"fetched_at":1,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":42,"nextResetTime":9}]}}' ]; then
      ok "fetcher: empty limits leaves a good cache untouched"
    else
      bad "fetcher: empty limits leaves a good cache untouched (rc=$rc)"
    fi
    rm -f "$TH/.claude/zaiquota/quota.cache"
    out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ ! -f "$TH/.claude/zaiquota/quota.cache" ] && [[ "$out" == *"empty limits"* ]]; then
      ok "fetcher: empty limits with no cache seeds nothing (n/a stays honest)"
    else
      bad "fetcher: empty limits with no cache seeds nothing (rc=$rc)"
    fi
  fi
  kill "$SRVPID" 2>/dev/null
  rm -rf "$TH"
else
  # python3 missing: the whole server block is unreachable — skip all four
  # server-fed checks so the tally always sums (same as the bind-failure path)
  skipped "junk-200 (python3 missing)"
  skipped "valid 200 writes a 0600 cache (python3 missing)"
  skipped "empty limits leaves a good cache untouched (python3 missing)"
  skipped "empty limits with no cache seeds nothing (python3 missing)"
fi

# ---- hooks.json contract ----
# the next greps look for literal ${...} strings:
# shellcheck disable=SC2016
if grep -q '${CLAUDE_PLUGIN_ROOT}/scripts' hooks/hooks.json \
   && grep -qF '${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}' hooks/hooks.json \
   && [ "$(jq '.hooks.SessionStart[0].hooks | length' hooks/hooks.json)" = "2" ] \
   && ! jq -e '.hooks.SessionStart[0].hooks[0].async == true' hooks/hooks.json >/dev/null 2>&1 \
   && jq -e '.hooks.SessionStart[0].hooks[1].async == true' hooks/hooks.json >/dev/null 2>&1; then
  ok "hooks.json: sync entry blocks, session fetch is async, stable-path contract"
else
  bad "hooks.json: sync entry blocks, session fetch is async, stable-path contract"
fi

# ensure-current chains before quota hook on prompt submit / turn end — and via
# ";" not "&&": ensure-current runs from the ephemeral plugin root (it may be
# garbage-collected after a second update), the quota hook after it must run
# unconditionally
# the next greps look for literal ${...} strings:
# shellcheck disable=SC2016
if [ "$(grep -cF 'ensure-current.sh' hooks/hooks.json)" = "2" ] \
   && grep -qF '\"${CLAUDE_PLUGIN_ROOT}/scripts/ensure-current.sh\" ; \"${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/quota-hook.sh\" pre' hooks/hooks.json \
   && grep -qF '\"${CLAUDE_PLUGIN_ROOT}/scripts/ensure-current.sh\" ; \"${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/quota-hook.sh\" post' hooks/hooks.json; then
  ok "hooks.json: ensure-current chains before quota hook on prompt/stop"
else
  bad "hooks.json: ensure-current chains before quota hook on prompt/stop"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
if [ "$fail" -gt 0 ]; then exit 1; fi
if [ "${CI:-}" = "true" ] && [ "$skip" -gt 0 ]; then
  echo "FAIL: tests were skipped in CI — coverage there must be complete" >&2
  exit 1
fi
exit 0
