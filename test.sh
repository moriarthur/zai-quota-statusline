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
sb() { printf '%s' "$1" | env ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh; }

IN='{"model":{"display_name":"glm-5.3-flash[1m]"},"context_window":{"used_percentage":62},"cost":{"total_cost_usd":5.1}}'
check "statusline: exact model (1M marker stripped)" "GLM-5.3-Flash" sb "$IN"
check "statusline: context-left from used%"         "context left 38%" sb "$IN"
check "statusline: session cost"                    "\$5.10"           sb "$IN"
check "statusline: 5h/7d segments"                  "7d"               sb "$IN"
check "statusline: tier resolved via env mapping"   "GLM-5.3-Flash"    env ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3-flash ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< '{"model":{"display_name":"Sonnet 4.5"}}'
check "statusline: empty stdin falls back"          "Claude"           env ZAI_SB_CACHE=/tmp/zai-ci-nope bash scripts/zai-statusline.sh </dev/null
check "statusline: no cache is quiet"               "quota n/a"        env ZAI_SB_CACHE=/tmp/zai-ci-nope bash scripts/zai-statusline.sh </dev/null
PILL_CAP=$(printf '\ue0b6')   # Nerd Font left pill cap (U+E0B6), ASCII escape so the glyph never travels through edits
absent "statusline: plain mode has no pill caps"    "$PILL_CAP"        env ZAI_SB_PLAIN=1 ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"
UNAME_TH=$(mktemp -d)
printf '#!/usr/bin/env bash\nprintf Darwin\n' > "$UNAME_TH/uname"
chmod +x "$UNAME_TH/uname"
MAC_DOT=$(printf '\u25cf')
absent "statusline: macOS has no Nerd Font pill caps" "$PILL_CAP" \
  env PATH="$UNAME_TH:$PATH" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"
check  "statusline: macOS keeps the plain status dot" "$MAC_DOT" \
  env PATH="$UNAME_TH:$PATH" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"
check  "statusline: macOS keeps the model name" "GLM-5.3-Flash" \
  env PATH="$UNAME_TH:$PATH" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"
rm -rf "$UNAME_TH"

# ---- jqsh: without jq on PATH the statusline must render identically ----
# macOS has no jq; the bundled jqsh (python3) substitutes. Stripping jq from
# PATH exercises the fallback end-to-end: same cache, same stdin, same line.
if command -v python3 >/dev/null 2>&1; then
  NOPATH=$(mktemp -d)
  for t in bash sh cat uname date sed tr cut head dirname python3 env mktemp chmod rm grep; do
    p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOPATH/$t"
  done
  plain=$(printf '%s' "$IN" | env ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh)
  shimmed=$(printf '%s' "$IN" | env PATH="$NOPATH" ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh)
  if [ -n "$plain" ] && [ "$plain" = "$shimmed" ]; then
    ok "statusline: jqsh fallback renders the identical line"
  else
    bad "statusline: jqsh fallback renders the identical line"
  fi
  rm -rf "$NOPATH"
else
  skipped "statusline: jqsh fallback (python3 missing)"
fi

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
          (.fetched_at // 0) ]
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
  && [ -x "$TH/zq/jqsh" ]; then
  ok "sync: installs all scripts executable"
else
  bad "sync: installs all scripts executable"
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

# ---- statusline: the dot breathes while a turn is live ----
# The pulse is an SGR-2 dim on even half-second steps, so these checks read RAW output
# (the suite's ANSI-stripper would erase the very thing under test).
FIXD=$(mktemp -d)
jq -n --argjson ts "$NOW" '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:21,nextResetTime:(($ts+3600)*1000)}]}}' > "$FIXD/quota.cache"
printf '%s\n' "$NOW" > "$FIXD/.turn"
dim=$'\033[2;38;5;'
raw=$(printf '%s' "$IN" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=2000 bash scripts/zai-statusline.sh)
if [[ "$raw" == *"$dim"* ]]; then
  ok "statusline: busy turn dims the dot on the breath-in tick"
else
  bad "statusline: busy turn dims the dot on the breath-in tick"
fi
raw=$(printf '%s' "$IN" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=2500 bash scripts/zai-statusline.sh)
if [[ "$raw" != *"$dim"* ]]; then
  ok "statusline: busy turn keeps the dot full on the breath-out tick"
else
  bad "statusline: busy turn keeps the dot full on the breath-out tick"
fi
rm -f "$FIXD/.turn"   # idle case: the breath-in test above left its flag behind
raw=$(printf '%s' "$IN" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=2000 bash scripts/zai-statusline.sh)
if [[ "$raw" != *"$dim"* ]]; then
  ok "statusline: idle dot is static (no turn flag)"
else
  bad "statusline: idle dot is static (no turn flag)"
fi
printf '0\n' > "$FIXD/.turn"   # stamp older than the 24h sanity cap
raw=$(printf '%s' "$IN" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=2000 bash scripts/zai-statusline.sh)
if [[ "$raw" != *"$dim"* ]]; then
  ok "statusline: stale turn flag does not pulse"
else
  bad "statusline: stale turn flag does not pulse"
fi
# per-session flag: only the owning session pulses
IN_SID='{"model":{"display_name":"X"},"session_id":"sb-pulse-test"}'
printf '%s\n' "$NOW" > "$FIXD/.turn-sb-pulse-test"
raw=$(printf '%s' "$IN_SID" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=2000 bash scripts/zai-statusline.sh)
if [[ "$raw" == *"$dim"* ]]; then
  ok "statusline: session-scoped turn flag pulses its own session"
else
  bad "statusline: session-scoped turn flag pulses its own session"
fi
rm -f "$FIXD/.turn-sb-pulse-test"
raw=$(printf '%s' "$IN_SID" | env -u ZAI_SB_CACHE ZAI_QUOTA_DIR="$FIXD" ZAI_SB_TEST_TICK=2000 bash scripts/zai-statusline.sh)
if [[ "$raw" != *"$dim"* ]]; then
  ok "statusline: another session's flag does not pulse this one"
else
  bad "statusline: another session's flag does not pulse this one"
fi
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
            "scripts/sync.sh 1" "scripts/quota-fetch.sh 1" "scripts/quota-hook.sh 1"; do
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
FIX2=$(mktemp)
jq -n --argjson ts "$NOW"   '{fetched_at:$ts, data:{limits:[
     {type:"TOKENS_LIMIT",percentage:10,number:7,unit:3,nextResetTime:(($ts+3600)*1000)},
     {type:"TOKENS_LIMIT",percentage:90,number:5,unit:1,nextResetTime:(($ts+172800)*1000)}]}}' > "$FIX2"
out=$(printf '%s' "$IN" | env ZAI_SB_CACHE="$FIX2" bash scripts/zai-statusline.sh 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')
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
out=$(printf '%s' "$IN" | env ZAI_SB_CACHE="$FIX4" bash scripts/zai-statusline.sh 2>&1 | strip_ansi)
if [[ "$out" == *"2h 45m"* && "$out" == *"1d 4h"* ]]; then
  ok "statusline: remaining time separates units (\"2h 45m\", \"1d 4h\")"
else
  bad "statusline: remaining time separates units (\"2h 45m\", \"1d 4h\")"
fi
rm -f "$FIX4"

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

ESC=$(printf '\033')
# \033[2J on purpose: the suite's ANSI-stripper only masks m-terminated SGR
# codes, so a clear-screen escape in the output would still be detected
absent "statusline: mapping values sanitized (no ANSI)" "$ESC" \
  env ANTHROPIC_DEFAULT_SONNET_MODEL=$'EVIL\033[2JGLM-9' ZAI_SB_CACHE=/tmp/zai-ci-nope \
  bash scripts/zai-statusline.sh <<< '{"model":{"display_name":"Sonnet 4.5"}}'

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
    # this is environmental, not a defect; skip rather than fail
    skipped "junk-200 (test server could not bind)"
  else
    printf '{"data":null}' > "$ENDPOINT"   # 200 with a junk body
    printf 'ANTHROPIC_BASE_URL=http://127.0.0.1:%s\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' "$PORT" > "$TH/.claude/zaiquota/config.env"
    out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [ ! -f "$TH/.claude/zaiquota/quota.cache" ] && [[ "$out" == *"unexpected response shape"* ]]; then
      ok "security: junk 200 leaves the cache untouched"
    else
      bad "security: junk 200 leaves the cache untouched (rc=$rc)"
    fi
    printf '{"data":{"limits":[]}}' > "$ENDPOINT"   # a valid 200
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CONFIG_DIR -u ZAI_QUOTA_DIR HOME="$TH" bash scripts/quota-fetch.sh --force >/dev/null 2>&1
    cacheperm=$(stat -c %a "$TH/.claude/zaiquota/quota.cache" 2>/dev/null || stat -f %Lp "$TH/.claude/zaiquota/quota.cache" 2>/dev/null)
    if [ -f "$TH/.claude/zaiquota/quota.cache" ] && [ "$cacheperm" = "600" ]; then
      ok "security: valid 200 writes a 0600 cache"
    else
      bad "security: valid 200 writes a 0600 cache (perm=$cacheperm)"
    fi
  fi
  kill "$SRVPID" 2>/dev/null
  rm -rf "$TH"
else
  skipped "junk-200 (python3 missing)"
fi

# ---- hooks.json contract ----
# the next greps look for literal ${...} strings:
# shellcheck disable=SC2016
if grep -q '${CLAUDE_PLUGIN_ROOT}/scripts' hooks/hooks.json \
   && grep -qF '${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}' hooks/hooks.json \
   && ! jq -e '.hooks.SessionStart[0].hooks[0].async == true' hooks/hooks.json >/dev/null 2>&1; then
  ok "hooks.json: plugin root + stable path contract"
else
  bad "hooks.json: plugin root + stable path contract"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
if [ "$fail" -gt 0 ]; then exit 1; fi
if [ "${CI:-}" = "true" ] && [ "$skip" -gt 0 ]; then
  echo "FAIL: tests were skipped in CI — coverage there must be complete" >&2
  exit 1
fi
exit 0
