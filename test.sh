#!/usr/bin/env bash
# Smoke tests — no network, no credentials. Run from anywhere: ./test.sh
# CI runs the same suite; every check prints ok/FAIL and the script exits 1 on any failure.
set -u
cd "$(dirname "$0")" || exit 1

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
if shellcheck scripts/*.sh test.sh 2>/dev/null; then ok "shellcheck"; else
  command -v shellcheck >/dev/null && bad "shellcheck" || printf 'skip shellcheck (not installed)\n'
fi

# ---- statusline fixtures ----
NOW=$(date +%s)
FIX=$(mktemp)
jq -n --argjson ts "$NOW" --argjson a 9 --argjson b 77 \
  --argjson ra "$(( (NOW + 10800) * 1000 ))" --argjson rb "$(( (NOW + 172800) * 1000 ))" \
  '{fetched_at:$ts, data:{limits:[{type:"TOKENS_LIMIT",percentage:$a,nextResetTime:$ra},{type:"TOKENS_LIMIT",percentage:$b,nextResetTime:$rb}]}}' > "$FIX"

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
printf '%s' '{"model":{"display_name":"X"},"context_window":{"used_percentage":"abc"},"cost":"1..2"}' \
  | env ZAI_SB_CACHE="$FIX" bash scripts/zai-statusline.sh >/tmp/zai_ci_out 2>/tmp/zai_ci_err
if ! grep -qE 'integer expression|invalid number' /tmp/zai_ci_err 2>/dev/null; then
  ok "statusline: numeric garbage stays silent"
else
  bad "statusline: numeric garbage stays silent"
fi
rm -f "$FIX" /tmp/zai_ci_out /tmp/zai_ci_err
ESC=$(printf '\033')
# \033[2J on purpose: the suite's ANSI-stripper only masks m-terminated SGR
# codes, so a clear-screen escape in the output would still be detected
absent "statusline: mapping values sanitized (no ANSI)" "$ESC" \
  env ANTHROPIC_DEFAULT_SONNET_MODEL=$'EVIL\033[2JGLM-9' ZAI_SB_CACHE=/tmp/zai-ci-nope \
  bash scripts/zai-statusline.sh <<< '{"model":{"display_name":"Sonnet 4.5"}}'

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

# ---- security: the token never travels further than the configured host ----
# env -u strips real credentials so the tests never touch the live API
TH=$(mktemp -d)
mkdir -p "$TH/.claude/zaiquota"
printf 'ANTHROPIC_BASE_URL=https://127.0.0.1:1/api/anthropic\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' > "$TH/.claude/zaiquota/config.env"
out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" != *"DUMMY_TOKEN_VALUE"* ]]; then
  ok "security: failed fetch never echoes the token"
else
  bad "security: failed fetch never echoes the token (exit $rc)"
fi
printf 'ANTHROPIC_BASE_URL=http://insecure.example.com/api/anthropic\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' > "$TH/.claude/zaiquota/config.env"
out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
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
    printf 'skip security: junk-200 (test server could not bind)\n'
  else
    printf '{"data":null}' > "$ENDPOINT"   # 200 with a junk body
    printf 'ANTHROPIC_BASE_URL=http://127.0.0.1:%s\nANTHROPIC_AUTH_TOKEN=DUMMY_TOKEN_VALUE\n' "$PORT" > "$TH/.claude/zaiquota/config.env"
    out=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL HOME="$TH" bash scripts/quota-fetch.sh --force 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [ ! -f "$TH/.claude/zaiquota/quota.cache" ] && [[ "$out" == *"unexpected response shape"* ]]; then
      ok "security: junk 200 leaves the cache untouched"
    else
      bad "security: junk 200 leaves the cache untouched (rc=$rc)"
    fi
    printf '{"data":{"limits":[]}}' > "$ENDPOINT"   # a valid 200
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL HOME="$TH" bash scripts/quota-fetch.sh --force >/dev/null 2>&1
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
  printf 'skip security: junk-200 test (python3 missing)\n'
fi

# ---- hooks.json contract ----
# the next grep looks for a literal ${...} string:
# shellcheck disable=SC2016
if grep -q '${CLAUDE_PLUGIN_ROOT}/scripts' hooks/hooks.json && grep -q '\.claude/zaiquota' hooks/hooks.json; then
  ok "hooks.json: plugin root + stable path contract"
else
  bad "hooks.json: plugin root + stable path contract"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
