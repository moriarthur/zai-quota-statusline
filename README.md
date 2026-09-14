# zai-quota-statusline

[![CI](https://github.com/moriarthur/zai-quota-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/moriarthur/zai-quota-statusline/actions/workflows/ci.yml)

Event-driven Z.AI / GLM quota monitoring for [Claude Code](https://claude.com/claude-code) —
**no cron, no fixed timers, no polling**. The quota cache refreshes the moment you submit a
prompt and again when the turn finishes, so the statusline always shows fresh numbers.

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
> severity. Colors already on the cube (`38;5;65/173/131`) are identity-mapped by such
> quantizers, so the status line looks the same everywhere.

```
 ● GLM-5.3-Flash | 5h ━━━━━━──── 60% 2h 14m · 7d ━━━━━━━─── 77% 4d 3h · context left 38% · $5.10
```

## How it works

```
prompt submitted ──▶ UserPromptSubmit hook ─▶ quota fetch (async) ─▶ Claude processes
                                                                           │
        fresh quota in statusline ◀── Stop hook ─▶ quota fetch ◀── turn ends
```

The hooks are `async`, so they **never add latency** to prompt processing. A PID-symlink
lock plus an event-aware dedup window (8 s, tunable) collapse duplicate hook firings and
parallel sessions; the fetch itself is a single plain GET to Z.AI's plan-usage endpoint —
one call per prompt/turn cycle, nothing in between. The same hooks also stamp a
per-session turn flag (`.turn-<session_id>`) that the statusline reads to pulse the dot
during a live turn — a file stamp, never an API call.

One boundary the hooks can't see: a 5h/7d window rolling over *between* turns would
leave the bars frozen on the expired window ("99% … 0m") until your next prompt. The
statusline notices a reset time in the past on its next render and nudges one forced
fetch in the background — throttled to one attempt per `ZAI_ROLL_MIN` seconds (default
60, stamp next to the cache). The fresh cache carries the new windows and the nudge
switches itself off.

## Requirements

- `bash` 3.2+, `curl`, and a JSON parser: `jq` — stock on Linux and WSL. macOS
  ships no jq; there the plugin automatically falls back to its bundled
  `jqsh` parser (runs on `python3`, which macOS provides with the Command Line
  Tools). `brew install jq` remains the fastest option but is not required
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

   `refreshInterval` (seconds) is what lets the dot breathe: while a turn is live the
   chip's dot pulses at 2 Hz, mirroring Claude's own spinner. Quota **fetching** stays
   event-driven — the timer only re-renders the line from the cache, it never calls the
   API. Without it the dot still pulses on every conversation event, just not on a steady
   beat.

3. Restart Claude Code. On session start the plugin syncs its scripts to the stable path
   `~/.claude/zaiquota/` (so plugin updates propagate automatically) and fetches the first
   quota snapshot before Claude starts rendering the statusline. This avoids an initial
   `quota n/a`; prompt/turn refreshes remain asynchronous.

### macOS Terminal

Claude Code uses the same plugin and settings from macOS Terminal, VS Code's integrated
terminal, and other terminals. They can differ only if their environment points Claude at
another config root via `CLAUDE_CONFIG_DIR`, or if `HOME` is different.

Nothing needs installing first: macOS ships no `jq`, so the plugin's scripts parse with
the bundled `jqsh` (a jq-subset interpreter run by `python3`, present with the Command
Line Tools). `brew install jq` is still the fastest parser if you have it, but it is
optional. Start Claude Code from the macOS Terminal and make sure `~/.claude/settings.json`
contains the `statusLine` block from step 2. Installing and enabling the plugin alone does
not create that block — plugins can register hooks, but Claude Code owns the statusline
setting. `/zai-quota-statusline:refresh` only fetches the quota cache; it cannot make a
statusline appear.

macOS Terminal draws the chip's Nerd Font pill caps as replacement glyphs (question
marks), so on macOS the chip switches to the plain `● model` form automatically — same
dot, usage color and busy-turn breath; every other platform keeps the pill.

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

> **No Nerd Font?** Set `ZAI_SB_PLAIN=1` in the status line command to skip the pill caps:
> `"command": "ZAI_SB_PLAIN=1 bash $HOME/.claude/zaiquota/zai-statusline.sh"`.

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
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/zaiquota/quota-hook.sh session", "timeout": 20 }] }],
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
| `ZAI_ROLL_MIN` | `60` | Throttle (s) for the statusline's forced refresh when a 5h/7d reset time has passed |
| `ZAI_FETCH_CURL_TIMEOUT` | `20` | Hard curl timeout (s) for a single request |
| `ZAI_SB_SEGMENTS` | `10` | Bar length in cells |
| `ZAI_SB_AGE` | `0` | `1` = append cache-age (`· 5m`) to the line |
| `ZAI_SB_PLAIN` | `0` | `1` = plain glyphs, no Nerd Font required |
| `ZAI_SB_CACHE` | `<base>/quota.cache` | Cache file location |
| `ZAI_QUOTA_DIR` | `$CLAUDE_CONFIG_DIR/zaiquota`, else `~/.claude/zaiquota` | Base directory for scripts, cache, config and logs (export it — hooks and the statusline inherit it) |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's config root; the plugin's base directory defaults to `$CLAUDE_CONFIG_DIR/zaiquota` when `ZAI_QUOTA_DIR` is unset |

## Files

| File | Role |
|---|---|
| `hooks/hooks.json` | Plugin hook registration (session-start sync + event-driven refresh) |
| `commands/refresh.md` | `/zai-quota:refresh` — force one fetch from the CLI |
| `scripts/sync.sh` | Session-start installer: atomically syncs the scripts into the stable path |
| `scripts/quota-fetch.sh` | Single GET to the Z.AI usage endpoint, response-shape validation, atomic cache write |
| `scripts/quota-hook.sh` | Hook wrapper: async-safe, PID-symlink lock, event-aware dedup, log + rotation |
| `scripts/zai-statusline.sh` | Statusline renderer: model chip, 5h/7d bars, context-left, cost |
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
- The statusline renders from the local cache only: no network access; model names are
  stripped of ANSI/control characters; the token is never part of its output.
- `quota.cache`, `hook.log` and hook state files are created with `0600` permissions.
- The fetch output never echoes the token; error bodies from the API are truncated.
- Tests (`./test.sh`) strip `ANTHROPIC_*` from the environment and use dummy tokens, so
  CI logs can never capture real credentials.

## License

MIT — see [LICENSE](LICENSE).
