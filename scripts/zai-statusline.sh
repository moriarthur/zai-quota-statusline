#!/usr/bin/env bash
# Custom Claude Code statusline — single line:
#
#   ● model | 5h <bar> 9% 2h 39m · 7d <bar> 77% 1d 4h · context left 85% · $5.14
#
# Chip: plain "● model" on every platform — no Nerd Font caps, nothing that
# depends on terminal fonts in CLI/IDE terminals, tmux or SSH. Bars are thin
# lines: heavy U+2501 fill (colored) + light U+2500 track (dim).
# Data: model / context / cost from the statusline stdin JSON; quotas from
# quota.cache (kept fresh by the UserPromptSubmit/Stop/SessionStart hooks).
set -o pipefail
umask 077   # hysteresis state, stamps and the opt-in debug log stay user-private

IN=$(cat)
DIR="${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}"
CACHE="${ZAI_SB_CACHE:-$DIR/quota.cache}"
SEGMENTS=${ZAI_SB_SEGMENTS:-10}
SHOW_AGE=${ZAI_SB_AGE:-0}

# jq is the only non-system dependency; macOS ships without it, so fall back to
# the bundled jqsh (a jq-subset interpreter run by python3) when it is absent.
command -v jq >/dev/null 2>&1 || \
  jq() { python3 "$(dirname "${BASH_SOURCE[0]}")/jqsh" "$@"; }

c_dim=$'\033[90m'; c_r=$'\033[0m'
# Palette: xterm-256 cube colors ONLY, never free-form truecolor.
# Some TUI statusline render paths quantize any truecolor to the 6x6x6 cube
# (each channel -> round(c/51) of {0,95,135,175,215,255}), which rounded the
# dark red's green channel UP (77 -> 135) and turned it into a brighter orange
# than the 50-79% tier — inverting severity on screen. On-cube colors are
# identity-mapped by such quantizers, so what we pick is what renders.
C_GREEN='38;5;65'     # (95,135,95)  sage
C_ORANGE='38;5;173'   # (215,135,95) amber
C_RED='38;5;131'      # (175,95,95)  brick-rose
DOT=$'●'                       # status dot in the chip, colored by usage degree
HEAVY=$'━'; LIGHT=$'─'    # bar: heavy fill / light track

col() { # usage pct -> fg SGR params: <50 green / <80 orange / >=80 red (Claude brand palette)
  if   [ "$1" -lt 50 ]; then printf '%s' "$C_GREEN"
  elif [ "$1" -lt 80 ]; then printf '%s' "$C_ORANGE"
  else                       printf '%s' "$C_RED"; fi
}

num() { # sanitize anything numeric-ish into a plain non-negative integer
  case "${1:-}" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$1" ;; esac
}

# Breath ramp: two tones — a hueless dim gray (the dot reading as "off") and
# the tier color. Explicit 38;5;N codes, never SGR faint — faint is exactly
# the attribute some render paths drop, and on-cube codes pass the quantizing
# backends unchanged.
ramp() { # $1=tier SGR params -> R_DIM R_LO
  R_DIM=240                 # (88,88,88) — the "out" endpoint, deliberately hueless
  case "$1" in
    "$C_GREEN")  R_LO=65 ;;
    "$C_ORANGE") R_LO=137 ;;
    *)           R_LO=95 ;;
  esac
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
model=${model:-Claude}   # jq failed on empty/malformed stdin — keep the chip labeled
# sanitize LAST: both display_name and the tier_model mapping feed the chip.
# Explicit case pairs, not the GNU sed `I` flag — BSD sed (macOS) rejects it,
# and a failing sed here would blank the whole model pipeline.
model=$(printf '%s' "$model" \
  | sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g' \
  | tr -d '[:cntrl:]' | cut -c1-40 \
  | sed -E 's/^[Gg]lm/GLM/; s/-[Ff]lash/-Flash/g; s/-[Aa]ir/-Air/g')

# ---- quotas ----
h5p=0 h5r=0 wp=0 wr=0 fetched=0
if [ -f "$CACHE" ]; then
  IFS=$'\t' read -r h5p h5r wp wr fetched src < <(
    # Labels assume the standard plan: two TOKENS_LIMIT windows of 5 hours and
    # 7 days. Near the weekly reset, reset-time order would swap the labels —
    # so when both windows carry distinct `number` fields (5 and 7) we label
    # by number; otherwise (e.g. CREDIT_LIMIT on lite plans) reset-time order
    # is the best available signal. Field 6 carries the source ("w"=token
    # windows, "c"=credit fallback) — credit windows render as one "quota"
    # bar, they are not 5-hour/weekly windows.
    jq -r '(.data.limits // []) as $l
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
      | @tsv' "$CACHE" 2>/dev/null
  )
  h5p=${h5p:-0}; h5r=${h5r:-0}; wp=${wp:-0}; wr=${wr:-0}; fetched=${fetched:-0}
  h5p=$(num "$h5p"); h5r=$(num "$h5r"); wp=$(num "$wp"); wr=$(num "$wr"); fetched=$(num "$fetched")
  case "$src" in c) ;; *) src=w ;; esac   # anything odd reads as token windows
fi

now=$(date +%s)

# ---- background nudges ----
# One shared escape hatch for "the cache is wrong or absent and no hook is coming
# to fix it": spawn one quota-fetch --force in the background, stamped next to the
# cache (stamp written first, so a re-render every second cannot pile up spawns) —
# one attempt per ZAI_ROLL_MIN seconds (default 60). The spawn routes through the
# hook wrapper (quota-hook.sh session), so the fetch inherits the wrapper's fetch
# lock, event dedup and hook.log visibility — a cold-start race between the async
# session hook and the first render resolves to exactly one fetch.
nudge() {
  local rmin last stamp lock holder
  rmin=$(num "${ZAI_ROLL_MIN:-60}")
  [ "$rmin" -lt 1 ] && rmin=60
  stamp="$(dirname "$CACHE")/.rollrefresh"
  # Atomic claim (same PID-symlink idiom as the fetch lock): two parallel
  # renders — two Claude windows on one project — must not both pass the stamp
  # check and double-spawn the background fetch.
  lock="$stamp.lock"
  if [ -L "$lock" ]; then
    holder=$(readlink "$lock" 2>/dev/null)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      return 0                            # a sibling render holds the claim
    fi
  fi
  rm -rf "$lock"
  ln -s "$$" "$lock" 2>/dev/null || return 0
  # Defer to an in-flight hook fetch — it writes the cache itself, so a cold
  # start fires one fetch instead of two. Retrying is free: the stamp is not
  # written here, so a later render may nudge again if the hook fetch died.
  if [ -L "$DIR/.fetch.lock" ]; then
    holder=$(readlink "$DIR/.fetch.lock" 2>/dev/null)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock"
      return 0
    fi
  fi
  last=$(num "$(head -1 "$stamp" 2>/dev/null)")
  if [ $(( now - last )) -ge "$rmin" ]; then
    printf '%s\n' "$now" >"$stamp" 2>/dev/null || true
    # through the hook wrapper, not quota-fetch directly — lock + dedup make the
    # cold-start race with the async session hook resolve to one fetch; stdin
    # closed so the hook never inherits this render's JSON
    ( "$(dirname "${BASH_SOURCE[0]}")/quota-hook.sh" session </dev/null >/dev/null 2>&1 & )
  fi
  rm -rf "$lock"   # release even when throttled — the claim guards the spawn only
}

# Rollover: the hooks refresh on prompts and turn ends only, so a 5h/7d reset
# that passes between turns would freeze the bars on the old window
# ("99% ... 0m") until the next prompt. A cached reset time in the past nudges;
# the fresh cache carries the new windows and the nudge switches itself off.
roll=0
[ "$h5r" -gt 0 ] && [ "$h5r" -le "$now" ] && roll=1
[ "$wr" -gt 0 ] && [ "$wr" -le "$now" ] && roll=1
[ "$roll" = 1 ] && nudge

# No usable windows: "quota n/a" can also mean the session hook never ran
# (killed hook, missed install) — or the cache holds a payload with zero
# renderable windows. Observed 2026-09-15: a shape-valid `limits: []` (the API
# mid-swap of the 5h window) reached the cache and froze the line at n/a until
# the next prompt; fetchers older than 0.1.18 could store it, and any future
# shape that parses to nothing looks identical here. Only a fresh fetch can fix
# such a render, so an absent OR window-less cache nudges — the shared stamp
# keeps even a permanently empty shape at one GET per ZAI_ROLL_MIN — and only
# with credentials discoverable — config.env on disk, or ANTHROPIC_AUTH_TOKEN
# in this process's environment, the fetcher's own resolution order (env first,
# file fallback) — so an unconfigured install never spawns. Mutually
# exclusive with the rollover trigger above (that one needs a parsed window).
if { [ -f "$DIR/config.env" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; } \
   && { [ ! -f "$CACHE" ] || [ "$h5r" -eq 0 ]; }; then
  nudge
fi

# ---- turn flag ----
# The hooks stamp .turn[-<session_id>] at prompt submit and clear it at turn
# end, so "a turn is live" is knowable without a busy field in the stdin JSON
# (there is none). No flag = idle: static dot.
busy=0
sid=$(jq -r '.session_id // empty' <<<"$IN" 2>/dev/null)
case "$sid" in ''|*[!A-Za-z0-9_-]*) sid='' ;; esac
for f in "$DIR/.turn${sid:+-$sid}" "$DIR/.turn"; do
  [ -f "$f" ] || continue
  [ "$(( now - $(num "$(head -1 "$f" 2>/dev/null)") ))" -lt 86400 ] && { busy=1; break; }
done

remain() { # epoch -> "3h 39m" / "1d 5h" / "12m"
  local r=$(( ${1:-0} - now )); [ "$r" -lt 0 ] && r=0
  local d=$(( r / 86400 )) h=$(( (r % 86400) / 3600 )) m=$(( (r % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
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
  l1='5h '; l2='7d '   # labels carry their own trailing space
  if [ "$src" = "c" ]; then
    # Z.AI renamed the plan windows to CREDIT_LIMIT (observed 2026-09-15):
    # same two windows, same data, so with both present the familiar 5h/7d
    # labels apply; a lone credit window has no verifiable name — bare bar
    [ "$wr" -gt 0 ] || { l1=''; l2=''; }
  fi
  q=$(printf '%s%s \033[%sm%s%%\033[39m %s%s ' \
    "$l1" "$(bar "$h5p")" "$(col "$h5p")" "$h5p" "$c_dim" "$(remain "$h5r")")
  if [ "$wr" -gt 0 ]; then
    q+=$(printf '%s·%s %s%s \033[%sm%s%%\033[39m %s%s ' \
      "$c_dim" "$c_r" "$l2" "$(bar "$wp")" "$(col "$wp")" "$wp" "$c_dim" "$(remain "$wr")")
  fi
  if [ "$SHOW_AGE" = 1 ] && [ "$fetched" -gt 0 ]; then
    q+=$(printf '%s- %sm%s ' "$c_dim" "$(( (now - fetched) / 60 ))" "$c_r")
  fi
else
  q=$(printf '%squota n/a%s' "$c_dim" "$c_r")
fi
q=${q%' '}   # drop one trailing space so the `·` separator below isn't doubled

# ---- context-left hysteresis ----
# The statusline payload builder (VAt in the CC binary) lacks the zero-usage
# guard its /context path has, so a transient zero-sum usage object — a streaming
# message's placeholder — arrives as used_percentage:0 and the line flashes
# "context left 100%" until the real response usage lands. The placeholder can
# persist for MANY frames (observed ~5 s at a 1 Hz floor), so a jump >=
# ZAI_SB_CTX_JUMP points (default 10) is held until it repeats on 2 CONSECUTIVE
# identical frames AND a literal 100 is never accepted over an existing shown
# value at all: used=0 is exactly what the placeholder looks like, and the only
# honest way to display a real /clear is the next real (used > 0) frame. Falls
# and smaller rises show at once. State is per session in ".ctx[-<sid>]"
# (shown|candidate|count|ts), left untouched by steady renders, stale after
# 300 s. A real compaction lands ~2 s late — held briefly, never hidden.
CTX_HOLD_PTS=${ZAI_SB_CTX_JUMP:-10}
ctx_hyst() { # $1=raw ctxl -> prints the value to display
  local st="$DIR/.ctx${sid:+-$sid}" V=$1 S='' C=0 N=0 T=0 prev show nS nC nN tmp
  if [ -f "$st" ]; then
    IFS='|' read -r S C N T _ <"$st" 2>/dev/null
    S=$(num "$S"); C=$(num "$C"); N=$(num "$N"); T=$(num "$T")
  fi
  prev=$S
  if [ -n "$S" ] && [ $(( now - T )) -le 300 ]; then
    if [ "$V" -eq 100 ]; then
      # used_percentage:0 — the payload's streaming placeholder. It can persist
      # for many frames (observed ~5 s at a 1 Hz floor), so the two-frame
      # confirmation never sees it end: once a real value has been shown this
      # session, a literal 100 NEVER displaces it — nor a pending confirmation.
      # A genuine /clear updates on the first real (used > 0) frame instead.
      show=$S; nS=$S; nC=$C; nN=$N
    elif [ "$V" -le "$S" ] || [ $(( V - S )) -lt "$CTX_HOLD_PTS" ]; then
      show=$V; nS=$V; nC=0; nN=0              # fall or small rise: show at once
    elif [ "$C" = "$V" ] && [ "$N" -ge 1 ]; then
      nN=$(( N + 1 ))
      if [ "$nN" -ge 2 ]; then show=$V; nS=$V; nC=0; nN=0   # confirmed twice
      else show=$S; nS=$S; nC=$V; fi                        # held one more frame
    else
      show=$S; nS=$S; nC=$V; nN=1                            # new candidate: hold
    fi
  else
    show=$V; nS=$V; nC=0; nN=0                               # no/stale state: raw
  fi
  if [ -z "$S" ] || [ "$nS|$nC|$nN" != "$S|$C|$N" ]; then
    # process-unique temp + rename: a parallel render or the age sweep never
    # sees a torn file — same atomic idiom as the cache write
    tmp="$st.$$"
    if printf '%s|%s|%s|%s\n' "$nS" "$nC" "$nN" "$now" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$st" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  # diagnostics (ZAI_SB_DEBUG=1): incidents only — a held jump or a displayed
  # change, never steady renders. Totals from current_usage; rotated like hook.log.
  if [ "$ZAI_SB_DEBUG" = 1 ] && { [ "$show" != "$V" ] || { [ -n "$prev" ] && [ "$show" != "$prev" ]; }; }; then
    local lg="$DIR/statusline-debug.log" sz io
    sz=$(num "$(wc -c <"$lg" 2>/dev/null)")
    [ "$sz" -gt 262144 ] && : >"$lg"
    io=$(jq -r '[(.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0), (.context_window.current_usage.output_tokens // 0)] | @tsv' <<<"$IN" 2>/dev/null)
    printf '%s|%s|used=%s|remaining=%s|shown=%s|held=%s|in=%s|out=%s\n' \
      "$now" "${sid:-none}" "$(( 100 - V ))" "$V" "$show" \
      "$([ "$show" != "$V" ] && printf 1 || printf 0)" \
      "${io%%$'\t'*}" "${io##*$'\t'}" >>"$lg" 2>/dev/null || true
  fi
  printf '%s\n' "$show"
}

# ---- right-side facts: context usage + session cost ----
# used and remaining are one computation in CC (remaining = 100 - used, clamped
# to 0..100), so used_percentage alone is the source.
extra=''
ctxp=$(jq -r '.context_window.used_percentage // empty' <<<"$IN" 2>/dev/null)
if [ -n "$ctxp" ]; then
  ctxp=${ctxp%.*}   # floor if float
  ctxp=$(num "$ctxp")
  [ "$ctxp" -gt 100 ] && ctxp=100
  ctxl=$(ctx_hyst "$(( 100 - ctxp ))")
  ctxc=$(col "$(( 100 - ctxl ))")   # color tracks the DISPLAYED usage, not raw
  extra+=$(printf '%scontext left \033[%sm%s%%\033[39m' "$c_dim" "$ctxc" "$ctxl")
fi
# total_cost_usd is Claude Code's own list-price estimate for the session (reset
# by /clear) — not the Z.AI invoice. A value that is not a number, or a negative
# one (no such estimate exists), hides the segment instead of posing as $0.00.
# printf (strtod) is the parser: it accepts scientific notation, and only a
# non-number fails — its exit code separates "abc" from "1e-05". LC_NUMERIC=C:
# %f is locale-aware, and a ru-RU terminal would otherwise render "5,10".
cost=$(jq -r '.cost.total_cost_usd // empty' <<<"$IN" 2>/dev/null)
if [ -n "$cost" ]; then
  case "$cost" in -*) cost='' ;; esac   # a negative estimate is not a real value
fi
if [ -n "$cost" ]; then
  cost=$(LC_NUMERIC=C printf '%.2f' "$cost" 2>/dev/null) || cost=''
fi
if [ -n "$cost" ]; then
  [ -n "$extra" ] && extra+=" ${c_dim}·${c_r} "   # same dim separator style as the quota segments
  extra+=$(printf '%s$%s%s' "$c_dim" "$cost" "$c_r")
fi

# ---- turn breath + model chip ----
# While a turn is live the dot breathes between two tones — the dim gray
# "off" end and the tier color — one second a tone, toggling every beat of
# the host's render floor (statusLine.refreshInterval, min 1 s): a full
# cycle every 2 s, the fastest flicker the host can draw. Faster
# event-driven re-renders within the same second land on the same tone.
# Idle: the tier color, static. The chip is plain everywhere: "● model", the
# dot carrying the color.
glc=$(col "$h5p")
if [ "$busy" = 1 ]; then
  tick=${ZAI_SB_TEST_TICK:-$now}   # test seam: freeze the clock (whole seconds)
  ramp "$glc"
  case $(( tick % 2 )) in
    1) glc="38;5;$R_LO" ;;   # the tier tone, one beat
    *) glc="38;5;$R_DIM" ;;  # the gray "off" end, one beat
  esac
fi
chip=$(printf '\033[%sm%s\033[0m %s' "$glc" "$DOT" "$model")

# ---- assemble ----
line="$chip ${c_dim}|${c_r} $q"
[ -n "$extra" ] && line+=" ${c_dim}·${c_r} $extra"
printf '%s' "$line"
