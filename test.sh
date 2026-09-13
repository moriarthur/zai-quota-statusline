#!/usr/bin/env bash
# Smoke tests — no network, no credentials. Run from anywhere: ./test.sh
# CI runs the same suite; every check prints ok/FAIL and the script exits 1 on any failure.
set -u
cd "$(dirname "$0")"

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

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
if shellcheck scripts/*.sh 2>/dev/null; then ok "shellcheck"; else
  command -v shellcheck >/dev/null && bad "shellcheck" || printf 'skip shellcheck (not installed)\n'
fi

# ---- statusline fixtures ----
NOW=$(date +%s)
FIX=$(mktemp)
jq -n --argjson ts "$NOW" --argjson a 9 --argjson b 77 \
  --argjson ra "$(( (NOW + 10800) * 1000 ))" --argjson rb "$(( (NOW + 172800) * 1000 ))" \
  '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:$a,nextResetTime:$ra},{type:"TOKENS_LIMIT",percentage:$b,nextResetTime:$rb}]}}' > "$FIX"

sb() { printf '%s' "$1" | env ZAI_SB_CACHE="$FIX" ${2:-} bash scripts/zai-statusline.sh; }

IN='{"model":{"display_name":"glm-5.3-flash[1m]"},"context_window":{"used_percentage":62},"cost":{"total_cost_usd":5.1}}'
check "statusline: exact model (1M marker stripped)" "GLM-5.3-Flash" sb "$IN"
check "statusline: context-left from used%"         "context left 38%" sb "$IN"
check "statusline: session cost"                    '$5.10'            sb "$IN"
check "statusline: 5h/7d segments"                  "7d"               sb "$IN"
check "statusline: tier resolved via env mapping"   "GLM-5.3-Flash"    env ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3-flash ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< '{"model":{"display_name":"Sonnet 4.5"}}'
check "statusline: empty stdin falls back"          "Claude"           env ZAI_SB_CACHE=/tmp/zai-ci-nope bash scripts/zai-statusline.sh </dev/null
check "statusline: no cache is quiet"               "quota n/a"        env ZAI_SB_CACHE=/tmp/zai-ci-nope bash scripts/zai-statusline.sh </dev/null
PILL_CAP=$(printf '\ue0b6')   # Nerd Font left pill cap (U+E0B6), ASCII escape so the glyph never travels through edits
absent "statusline: plain mode has no pill caps"    "$PILL_CAP"        env ZAI_SB_PLAIN=1 ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh <<< "$IN"
rm -f "$FIX"

# ---- hook: isolated HOME, no credentials -> logs the attempt, still exit 0 ----
# (env -u strips any inherited ANTHROPIC_* so the test never touches the network)
TH=$(mktemp -d)
printf '{}' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL HOME="$TH" bash scripts/quota-hook.sh pre >/dev/null 2>&1
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

# ---- fetcher: missing credentials fail loudly ----
TH=$(mktemp -d)
out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"ANTHROPIC_AUTH_TOKEN"* ]]; then
  ok "fetcher: missing token fails with a clear message"
else
  bad "fetcher: missing token fails with a clear message (exit $rc)"
fi
rm -rf "$TH"

# ---- hooks.json contract ----
if grep -q '${CLAUDE_PLUGIN_ROOT}/scripts' hooks/hooks.json && grep -q '\.claude/zaiquota' hooks/hooks.json; then
  ok "hooks.json: plugin root + stable path contract"
else
  bad "hooks.json: plugin root + stable path contract"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
