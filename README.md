# zai-quota-statusline

[![CI](https://github.com/moriarthur/zai-quota-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/moriarthur/zai-quota-statusline/actions/workflows/ci.yml)

Event-driven Z.AI / GLM quota monitoring for [Claude Code](https://claude.com/claude-code) —
**no cron, no quota polling**. The cache refreshes the moment you submit a prompt and again
when the turn finishes; the statusline reads the local cache and never calls the API on a
schedule (the optional 1 s re-render reads the cache only).

**Design goal:** the line should feel *native to Claude Code*. Everything lives in the CLI
you already work in — a model chip with a usage-colored dot that **breathes while a turn is
live** (like the native spinner), usage bars in a green → orange →
red severity scale (xterm-256 cube colors, see below), context-left and
session cost — visible in real time, with no manual refresh requests and no browser
dashboard.

> **Why 256-color palette codes?** Some terminal render paths (e.g. a TUI redrawing the
> status line through a 256-color backend) quantize any truecolor to the xterm cube —
> each channel snapped via `round(c/51)`. That rounding can push a dark red's green
> channel *up* until it renders brighter than the orange tier, visually inverting
> severity. Colors already on the cube are identity-mapped by such quantizers, so the
> status line looks the same everywhere: the tier colors `38;5;65/173/131`, and the
> busy dot breathing between a dim gray (`38;5;240`) and the tier color — explicit
> `38;5;N` codes rather than SGR faint, another attribute render paths drop.

```
● GLM-5.3-Flash | 5h ━━━━━━──── 60% 2h 14m · 7d ━━━━━━━─── 77% 4d 3h · context left 38% · $5.10
```

## How it works

```
prompt submitted ──▶ UserPromptSubmit hook ─▶ quota fetch (async) ─▶ Claude processes
                                                                           │
        fresh quota in statusline ◀── Stop hook ─▶ quota fetch ◀── turn ends
```

The prompt and turn hooks are `async`, so they **never add latency** to prompt
processing; the session-start hook is asynchronous too — startup only runs a fast,
blocking script sync, and the first quota fetch fires in the background (step 3), so a
stalled network can never hold Claude Code hostage. A PID-symlink lock plus an
event-aware dedup window (8 s, tunable) collapse duplicate hook firings and parallel
sessions; the fetch itself is a single plain GET to Z.AI's plan-usage endpoint — one
call per prompt/turn cycle, nothing in between. The same hooks also carry a
millisecond-scale parity check (`ensure-current.sh`) that re-syncs the stable path when
a plugin update landed mid-session. They also stamp a
per-session turn flag (`.turn-<session_id>`) that the statusline reads to make the dot
breathe during a live turn — a file stamp, never an API call.

That endpoint (`/api/monitor/usage/quota/limit` on your base URL's origin) is an
internal Z.AI Coding Plan API, not part of the documented Anthropic-compatible surface
— it can change independently of it. The fetcher builds the URL from the origin only: a
path in `ANTHROPIC_BASE_URL` is used for the model API but ignored for quota.

One boundary the hooks can't see: a 5h/7d window rolling over *between* turns would
leave the bars frozen on the expired window ("99% … 0m") until your next prompt. The
statusline notices a reset time in the past on its next render and nudges one forced
fetch in the background — throttled to one attempt per `ZAI_ROLL_MIN` seconds (default
60, stamp next to the cache). The fresh cache carries the new windows and the nudge
switches itself off. And when the cache file is missing altogether — a session hook that
never ran or was killed — the next render nudges the same throttled background fetch on
its own, but only while `config.env` exists and only when the cache is truly absent: a
present but unparsable cache (an empty or unsupported quota response) is left alone.

The context-left number is filtered too. Claude Code's payload computes
`remaining_percentage` as `100 − used_percentage` in one expression — the statusline
reads `used_percentage` alone — but the payload builder has no zero-usage guard (the
`/context` path does), so a transient placeholder usage can arrive as
`used_percentage: 0` and flash "context left 100%" for a few renders. A rise of ≥10
points in context-left is held until it repeats on two consecutive identical frames —
per-session state, older than 300 s ignored — so the phantom never shows while a real
compaction lands about two seconds late. Falls and smaller rises show immediately.

The dollar figure is `cost.total_cost_usd` — Claude Code's own client-side list-price
estimate for the session (reset by `/clear`), **not** the Z.AI invoice. A value that is
not a number, or a negative one, hides the cost segment instead of posing as `$0.00`.

## Requirements

- `bash` 3.2+, `curl`, and a JSON parser: `jq` — stock on Linux and WSL. macOS
  ships no jq; there the plugin automatically falls back to its bundled
  `jqsh` parser (runs on `python3` — provided by the Command Line Tools, or
  `brew install python`). `brew install jq` remains the fastest option but is
  not required
- No platform-specific locking tools: the fetch lock is a PID-symlink claimed
  with a single atomic `symlink(2)` call, so Linux, WSL and macOS behave
  identically; on Windows use WSL

## Install (plugin)

```bash
claude plugin marketplace add moriarthur/zai-quota-statusline
claude plugin install zai-quota-statusline@moriarthur
```

or inside Claude Code: `/plugin marketplace add moriarthur/zai-quota-statusline`, then
`/plugin install zai-quota-statusline@moriarthur`.

1. Point the credentials file at your Z.AI token (`chmod 600`!):

   ```bash
   mkdir -p ~/.claude/zaiquota
   cat > ~/.claude/zaiquota/config.env <<'EOF'
   ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
   ANTHROPIC_AUTH_TOKEN=<your-token>
   EOF
   chmod 600 ~/.claude/zaiquota/config.env
   ```

2. Add the status line to `~/.claude/settings.json` (plugins can't set this field — it's
   one line):

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash $HOME/.claude/zaiquota/zai-statusline.sh",
       "padding": 0,
       "refreshInterval": 1
     }
   }
   ```

   `refreshInterval` (seconds) re-runs the statusline command on a steady beat — this is
   the documented Claude Code setting for periodic statusline updates, minimum 1 s. It is
   what lets the dot breathe (while a turn is live it flickers between a dim gray and
   the tier color — one second each, a full cycle every two seconds — one toggle per
   beat at this render floor, the fastest the host can draw) and what repaints the
   line when the startup cache lands a moment after the
   first render (see step 3). Quota **fetching** stays event-driven — the timer only
   re-renders the line from the cache, it never calls the API. Without it the line only
   re-renders on conversation events: a `quota n/a` drawn before the cache exists would
   sit there until your first prompt.

3. Restart Claude Code. On session start the plugin syncs its scripts to the stable path
   `~/.claude/zaiquota/` and fires the first quota fetch in the background — startup never
   waits on the network. Plugin **updates** propagate on their own: on every prompt submit
   and turn end a parity check re-syncs the stable path if the installed plugin's scripts
   have moved ahead of it, so after `/plugin update` (and `/reload-plugins` in the current
   session) the very next prompt brings the copy current — no restart, no manual sync. The
   first render can land before the startup fetch returns: with `refreshInterval: 1` from
   step 2 the line repaints within a second or two, and if the fetch never lands the
   statusline nudges its own throttled retry (see [Troubleshooting](#troubleshooting)).

### macOS Terminal

Claude Code uses the same plugin and settings from macOS Terminal, VS Code's integrated
terminal, and other terminals. They can differ only if their environment points Claude at
another config root via `CLAUDE_CONFIG_DIR`, or if `HOME` is different.

Nothing needs installing first: macOS ships no `jq`, so the plugin's scripts parse with
the bundled `jqsh` (a jq-subset interpreter run by `python3` — installed with the
Command Line Tools, or `brew install python`). `brew install jq` is still the fastest
parser if you have it, but it is optional. Start Claude Code from the macOS Terminal and make sure `~/.claude/settings.json`
contains the `statusLine` block from step 2. Installing and enabling the plugin alone does
not create that block — plugins can register hooks, but Claude Code owns the statusline
setting. `/zai-quota-statusline:refresh` only fetches the quota cache; it cannot make a
statusline appear. If `quota n/a` survives the launch itself, see
[Troubleshooting](#troubleshooting).

The chip is the same plain `● model` on every platform — macOS Terminal, VS Code and
JetBrains integrated terminals, tmux, SSH — with no Nerd Font prerequisite: it uses
common Unicode glyphs (`●`, `━`, `─`) found in stock terminal fonts. The former
pill-with-caps form is gone: rounded caps rendered as replacement glyphs wherever the
font was missing, which made them the one glyph-dependent element left in the line.

Useful checks from the same Terminal where Claude is started:

```bash
echo "HOME=$HOME"
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"
command -v jq >/dev/null && jq --version || echo "no jq — the bundled jqsh (python3) fallback parses"
jq '.statusLine' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("statusLine"))' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
ls -l "${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/zai-statusline.sh"
```

If the last two commands point to a different location than the one used in the
`statusLine.command`, update both paths to the same base directory and restart Claude Code.

> **Custom base directory?** The base directory resolves as
> `${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}`: an explicit
> `export ZAI_QUOTA_DIR=/path/to/dir` wins; otherwise it follows `CLAUDE_CONFIG_DIR`
> (a relocated Claude config root); otherwise `~/.claude/zaiquota`. Export your var of
> choice in the shell profile and point the status line at the same place:
> `"command": "bash ${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/zai-statusline.sh"`.
> Everything else — sync, hooks, `/refresh` — picks the directory up from the environment.
>
> **Already using `CLAUDE_CONFIG_DIR` (since 0.1.12)?** Move your existing data once so
> the plugin finds its token and cache at the new default:
> `mv ~/.claude/zaiquota "$CLAUDE_CONFIG_DIR/zaiquota"`.

## Troubleshooting

**`quota n/a` right after launch, until the first prompt or `/zai-quota-statusline:refresh`.**
The startup fetch wrote the cache a moment after Claude Code's first render — the line
just never got redrawn. Work through these in order:

1. Make sure the `statusLine` block contains `"refreshInterval": 1` — the documented
   Claude Code setting that re-runs the statusline command periodically (minimum 1 s).
   Without it the line only re-renders on conversation events, so a `quota n/a` drawn
   before the cache landed stays on screen until your first prompt.
2. Check the session-start fetch in the hook log:
   `tail -n 20 "${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/hook.log"`.
   A healthy start shows `session: force fetch` followed by `quota cache updated`;
   `fetch FAILED` or an `ERROR:` line says why it didn't.
3. Confirm the cache is there:
   `ls -l "${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/quota.cache"`.
   If the cache file is missing — or holds a payload with no usable windows — while
   `config.env` exists, the statusline nudges one throttled background fetch itself
   (same stamp and `ZAI_ROLL_MIN` window as the rollover nudge), so a missed session
   hook self-heals on a later render. The fetcher, for its part, never stores an
   empty `limits` snapshot: if the API answers mid-window-swap with `limits: []`, the
   previous cache stays on screen and the very next successful fetch refreshes it. In
   the rare case where the hook process died after writing its dedup state but before
   fetching, `quota n/a` can persist for up to `ZAI_ROLL_MIN` seconds — a minute at
   the default, while the line keeps re-rendering.
4. If the cache still never appears, check `config.env`: a regular file owned by you
   containing `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` (permissions are tightened
   to `600` automatically on every fetch). Fetch errors explain themselves in `hook.log`.

## Manual install (no plugin)

Copy the scripts from [`scripts/`](scripts/) to `~/.claude/zaiquota/`, make them
executable, create `config.env` as above, then merge into `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash $HOME/.claude/zaiquota/zai-statusline.sh",
    "padding": 0,
    "refreshInterval": 1
  },
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/zaiquota/quota-hook.sh session", "timeout": 20, "async": true }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/zaiquota/quota-hook.sh pre", "timeout": 20, "async": true }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/zaiquota/quota-hook.sh post", "timeout": 20, "async": true }] }]
  }
}
```

## Configuration (optional env vars)

| Variable | Default | Meaning |
|---|---|---|
| `ZAI_HOOK_DEDUP_SEC` | `8` | Dedup window for hook-driven fetches |
| `ZAI_HOOK_FETCH_TIMEOUT` | `15` | Hard timeout (s) for a single fetch |
| `ZAI_REFRESH_MIN` | `600` | Min age (s) of the cache before a plain (non-forced) fetch re-requests |
| `ZAI_ROLL_MIN` | `60` | Throttle (s) for the statusline's background forced refreshes — window rollover and missing-cache self-heal (shared stamp) |
| `ZAI_SB_CTX_JUMP` | `10` | Min rise (points) in context-left treated as a jump — held until it repeats on 2 identical frames |
| `ZAI_SB_DEBUG` | `0` | `1` = log incidents (held jumps, displayed changes) to `statusline-debug.log` — diagnostics only |
| `ZAI_FETCH_CURL_TIMEOUT` | `20` | Hard curl timeout (s) for a single request |
| `ZAI_SB_SEGMENTS` | `10` | Bar length in cells |
| `ZAI_SB_AGE` | `0` | `1` = append cache-age (`· 5m`) to the line |
| `ZAI_SB_CACHE` | `<base>/quota.cache` | Statusline cache read path (tests, exotic setups). Fetches always write `<base>/quota.cache` — point it there or at a symlink, or nothing will ever fill a custom path |
| `ZAI_QUOTA_DIR` | `$CLAUDE_CONFIG_DIR/zaiquota`, else `~/.claude/zaiquota` | Base directory for scripts, cache, config and logs (export it — hooks and the statusline inherit it) |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's config root; the plugin's base directory defaults to `$CLAUDE_CONFIG_DIR/zaiquota` when `ZAI_QUOTA_DIR` is unset |

## Files

| File | Role |
|---|---|
| `hooks/hooks.json` | Plugin hook registration (fast start-time sync, mid-session update re-sync, background first fetch, event-driven refresh) |
| `commands/refresh.md` | `/zai-quota-statusline:refresh` — force one fetch from the CLI |
| `scripts/sync.sh` | Session-start installer: atomically syncs the scripts into the stable path |
| `scripts/ensure-current.sh` | Parity check on prompt submit / turn end: re-syncs the stable path when a plugin update landed mid-session (report-only on orphan files, never deletes) |
| `scripts/quota-fetch.sh` | Single GET to the Z.AI usage endpoint, response-shape validation, atomic cache write |
| `scripts/quota-hook.sh` | Hook wrapper: async-safe, PID-symlink lock, event-aware dedup, log + rotation |
| `scripts/zai-statusline.sh` | Statusline renderer: model chip, 5h/7d bars, context-left, cost, self-healing nudges |
| `scripts/jqsh` | Bundled jq-subset parser (python3); used automatically when `jq` is not installed |

## Security

- The token lives only in `~/.claude/zaiquota/config.env` — create it with `chmod 600`
  (the install steps above do this). It is read by `quota-fetch.sh` and nothing else.
- `config.env` is **parsed, never executed** (plain `KEY=VALUE` lines): a tampered file
  cannot run code. It must be a regular file owned by you, and its permissions are
  tightened to `0600` automatically on every fetch.
- The token is sent **only** to your configured base URL and **only over https** — a
  plain-http base URL is refused with an error (loopback addresses excepted, for local
  testing).
- A HTTP 200 is validated against the expected response shape (`data.limits` array)
  before it can replace the cache — proxy splash pages can't poison it.
- The statusline renders from the local cache only: no network access of its own; model
  names are stripped of ANSI/control characters; the token is never part of its output.
  (It may nudge one throttled background `quota-fetch` when the cache file is missing —
  the same single-GET, https-only script the hooks use.)
- `quota.cache`, `hook.log`, hook state and statusline state files — and the opt-in
  `statusline-debug.log` — are created with `0600` permissions.
- The fetch output never echoes the token; error bodies from the API are truncated.
- Tests (`./test.sh`) strip `ANTHROPIC_*` from the environment and use dummy tokens, so
  CI logs can never capture real credentials.

## License

MIT — see [LICENSE](LICENSE).
