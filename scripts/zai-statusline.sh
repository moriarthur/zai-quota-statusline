#!/usr/bin/env bash
# Custom Claude Code statusline — single line:
#
#   <pill: dot + model> | 5h <bar> 9% 2h39m · 7d <bar> 77% 1d4h · context left 85% · $5.14
#
# Model chip uses Nerd Font rounded caps U+E0B6/U+E0B4 (ZAI_SB_PLAIN=1 renders a
# plain "● model" chip instead). Bars are thin lines: heavy U+2501 fill (colored)
# + light U+2500 track (dim).
# Data: model / context / cost from the statusline stdin JSON; quotas from
# quota.cache (kept fresh by the UserPromptSubmit/Stop/SessionStart hooks).
# Rollback: point statusLine.command back to ~/.claude/statusline-compose.sh.
set -o pipefail

IN=$(cat)
CACHE="${ZAI_SB_CACHE:-$HOME/.claude/zaiquota/quota.cache}"
SEGMENTS=${ZAI_SB_SEGMENTS:-10}
SHOW_AGE=${ZAI_SB_AGE:-0}
PLAIN=${ZAI_SB_PLAIN:-0}   # 1 = render without Nerd Font pill caps

c_dim=$'\033[90m'; c_r=$'\033[0m'
# Claude brand palette. Exact hexes on truecolor terminals, nearest 256-color
# codes otherwise. 256 green is 65 (#5F875F sage), NOT the mathematically
# nearest 101 (#87875F) — that one reads khaki next to warm Crail orange.
if [ "${COLORTERM:-}" = truecolor ] || [ "${COLORTERM:-}" = 24bit ]; then
  C_GREEN='38;2;120;140;93'    # #788C5D — Anthropic green
  C_ORANGE='38;2;217;119;87'   # #D97757 — Claude orange (Crail)
  C_RED='38;2;191;77;67'       # #BF4D43 — muted brick red (no official brand red; Crail-adjacent)
else
  C_GREEN='38;5;65'            # ≈ #5F875F
  C_ORANGE='38;5;173'          # ≈ #D7875F
  C_RED='38;5;131'             # ≈ #AF5F5F
fi
PL=$''; PR=$''         # pill caps (model chip)
DOT=$'●'                       # status dot in the chip, colored by usage degree
HEAVY=$'━'; LIGHT=$'─'    # bar: heavy fill / light track

col() { # usage pct -> fg SGR params: <50 green / <80 orange / >=80 red (Claude brand palette)
  if   [ "$1" -lt 50 ]; then printf '%s' "$C_GREEN"
  elif [ "$1" -lt 80 ]; then printf '%s' "$C_ORANGE"
  else                       printf '%s' "$C_RED"; fi
}

# ---- model (exact name as configured/launched) ----
# Claude Code reports the real model in .model.display_name/.id (e.g.
# "glm-5.3-flash[1m]" — [1m] marks the 1M-context build). When it only knows
# the Anthropic tier ("Sonnet 4.5"), resolve the Z.AI-style
# ANTHROPIC_DEFAULT_*_MODEL mapping: process env first, then the env block of
# the settings files.
tier_model() { # $1=var name $2=fallback if unmapped
  local v=${!1:-} f
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
    [ -n "$v" ] && break
    [ -f "$f" ] && v=$(jq -r --arg k "$1" '.env[$k] // empty' "$f" 2>/dev/null)
  done
  printf '%s' "${v:-$2}"
}
model=$(jq -r '.model.display_name // .model.id // empty' <<<"$IN" 2>/dev/null \
  | sed -E 's/\[[0-9]+m\]$//')
case "$model" in
  *[Oo]pus*)   model=$(tier_model ANTHROPIC_DEFAULT_OPUS_MODEL "$model") ;;
  *[Ss]onnet*) model=$(tier_model ANTHROPIC_DEFAULT_SONNET_MODEL "$model") ;;
  *[Hh]aiku*)  model=$(tier_model ANTHROPIC_DEFAULT_HAIKU_MODEL "$model") ;;
esac
model=${model:-Claude}   # jq failed on empty/malformed stdin — keep the pill labeled
model=$(printf '%s' "$model" | sed -E 's/^glm/GLM/I; s/-flash/-Flash/I; s/-air/-Air/I')

# ---- quotas ----
h5p=0 h5r=0 wp=0 wr=0 fetched=0
if [ -f "$CACHE" ]; then
  IFS=$'\t' read -r h5p h5r wp wr fetched < <(
    jq -r '(.data.limits // []) as $l
      | ([$l[] | select(.type == "TOKENS_LIMIT")] | sort_by(.nextResetTime)) as $tok
      | (if ($tok | length) > 0 then $tok
         else [$l[] | select(.type == "CREDIT_LIMIT")] | sort_by(.nextResetTime)
         end) as $t
      | [ (($t[0].percentage // 0) | floor),
          ((($t[0].nextResetTime // 0) / 1000) | floor),
          (($t[1].percentage // 0) | floor),
          ((($t[1].nextResetTime // 0) / 1000) | floor),
          (.fetched_at // 0) ]
      | @tsv' "$CACHE" 2>/dev/null
  )
  h5p=${h5p:-0}; h5r=${h5r:-0}; wp=${wp:-0}; wr=${wr:-0}; fetched=${fetched:-0}
fi

now=$(date +%s)
remain() { # epoch -> "3h39m" / "1d5h" / "12m"
  local r=$(( ${1:-0} - now )); [ "$r" -lt 0 ] && r=0
  local d=$(( r / 86400 )) h=$(( (r % 86400) / 3600 )) m=$(( (r % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else                      printf '%dm' "$m"; fi
}

bar() { # pct [fg] -> thin line: heavy fill (colored) + light track (dim)
  local pct=$1 fg=${2:-} f e out='' i
  [ -n "$fg" ] || fg=$(col "$pct")          # default: usage-threshold color
  f=$(( pct * SEGMENTS / 100 )); [ "$f" -gt "$SEGMENTS" ] && f=$SEGMENTS; [ "$f" -lt 0 ] && f=0
  [ "$f" -eq 0 ] && [ "$pct" -gt 0 ] && f=1
  e=$(( SEGMENTS - f ))
  for ((i = 0; i < f; i++)); do out+=$HEAVY; done
  printf '\033[%sm%s\033[0;90m' "$fg" "$out"
  out=''
  for ((i = 0; i < e; i++)); do out+=$LIGHT; done
  printf '%s\033[0m' "$out"
}

# ---- quota segments ----
q=''
if [ "$h5r" -gt 0 ]; then
  q=$(printf '5h %s \033[%sm%s%%\033[39m %s%s ' \
    "$(bar "$h5p")" "$(col "$h5p")" "$h5p" "$c_dim" "$(remain "$h5r")")
  if [ "$wr" -gt 0 ]; then
    q+=$(printf '%s·%s 7d %s \033[%sm%s%%\033[39m %s%s ' \
      "$c_dim" "$c_r" "$(bar "$wp")" "$(col "$wp")" "$wp" "$c_dim" "$(remain "$wr")")
  fi
  if [ "$SHOW_AGE" = 1 ] && [ "$fetched" -gt 0 ]; then
    q+=$(printf '%s- %sm%s ' "$c_dim" "$(( (now - fetched) / 60 ))" "$c_r")
  fi
else
  q=$(printf '%squota n/a%s' "$c_dim" "$c_r")
fi
q=${q%' '}   # drop one trailing space so the `·` separator below isn't doubled

# ---- right-side facts: context usage + session cost ----
extra=''
ctxp=$(jq -r '.context_window.used_percentage // empty' <<<"$IN" 2>/dev/null)
if [ -n "$ctxp" ]; then
  ctxp=${ctxp%.*}   # floor if float
  ctxl=$(jq -r '.context_window.remaining_percentage // empty' <<<"$IN" 2>/dev/null)
  if [ -n "$ctxl" ]; then ctxl=${ctxl%.*}; else ctxl=$(( 100 - ctxp )); fi
  ctxc=$(col "$ctxp")   # color still tracks usage; the number is what's left
  extra+=$(printf '%scontext left \033[%sm%s%%\033[39m' "$c_dim" "$ctxc" "$ctxl")
fi
cost=$(jq -r '.cost.total_cost_usd // empty' <<<"$IN" 2>/dev/null)
if [ -n "$cost" ]; then
  [ -n "$extra" ] && extra+=" ${c_dim}·${c_r} "   # same dim separator style as the quota segments
  extra+=$(printf '%s$%.2f%s' "$c_dim" "$cost" "$c_r")
fi

# ---- model chip ----
glc=$(col "$h5p")
if [ "$PLAIN" = 1 ]; then
  chip=$(printf '\033[%sm%s\033[0m %s' "$glc" "$DOT" "$model")
else
  chip=$(printf '\033[38;5;236m%s\033[0m\033[48;5;236m \033[%sm%s\033[0;48;5;236;38;5;252m %s \033[0m\033[38;5;236m%s\033[0m' \
    "$PL" "$glc" "$DOT" "$model" "$PR")
fi

# ---- assemble ----
line="$chip ${c_dim}|${c_r} $q"
[ -n "$extra" ] && line+=" ${c_dim}·${c_r} $extra"
printf '%s' "$line"
