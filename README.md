# zai-quota-statusline

[![CI](https://github.com/moriarthur/zai-quota-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/moriarthur/zai-quota-statusline/actions/workflows/ci.yml)

Event-driven Z.AI / GLM quota monitoring for [Claude Code](https://claude.com/claude-code) —
**no cron, no fixed timers, no polling**. The quota cache refreshes the moment you submit a
prompt and again when the turn finishes, so the statusline always shows fresh numbers.

**Design goal:** the line should feel *native to Claude Code*. Everything lives in the CLI
you already work in — a model chip with a usage-colored dot, usage bars in Claude's own
brand palette (green → orange → red; exact hexes on truecolor terminals), context-left and
session cost — visible in real time, with no manual refresh requests and no browser
dashboard.

```
 ● GLM-5.3-Flash | 5h ━━━━━━──── 60% 36d2h · 7d ━━━━━━━─── 77% 43d3h · context left 38% · $5.10
```

## How it works

```
prompt submitted ──▶ UserPromptSubmit hook ─▶ quota fetch (async) ─▶ Claude processes
                                                                           │
        fresh quota in statusline ◀── Stop hook ─▶ quota fetch ◀── turn ends
```

The hooks are `async`, so they **never add latency** to prompt processing. An event-aware
dedup window (`flock` + 8 s, tunable) collapses duplicate hook firings and parallel
sessions; the fetch itself is a single plain GET to Z.AI's plan-usage endpoint — one call
per prompt/turn cycle, nothing in between.

## Requirements

- `bash` 3.2+, `jq`, `curl` — stock on Linux and WSL; on macOS `brew install jq`
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
       "padding": 0
     }
   }
   ```

3. Restart Claude Code. On session start the plugin syncs its scripts to the stable path
   `~/.claude/zaiquota/` (so plugin updates propagate automatically), registers the hooks,
   and fetches the first quota snapshot. The statusline comes alive after the first prompt.

> **No Nerd Font?** Set `ZAI_SB_PLAIN=1` in the status line command to skip the pill caps:
> `"command": "ZAI_SB_PLAIN=1 bash $HOME/.claude/zaiquota/zai-statusline.sh"`.

## Manual install (no plugin)

Copy the three scripts from [`scripts/`](scripts/) to `~/.claude/zaiquota/`, make them
executable, create `config.env` as above, then merge into `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash $HOME/.claude/zaiquota/zai-statusline.sh",
    "padding": 0
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
| `ZAI_FETCH_CURL_TIMEOUT` | `20` | Hard curl timeout (s) for a single request |
| `ZAI_SB_SEGMENTS` | `10` | Bar length in cells |
| `ZAI_SB_AGE` | `0` | `1` = append cache-age (`· 5m`) to the line |
| `ZAI_SB_PLAIN` | `0` | `1` = plain glyphs, no Nerd Font required |
| `ZAI_SB_CACHE` | `~/.claude/zaiquota/quota.cache` | Cache file location |

## Files

| File | Role |
|---|---|
| `hooks/hooks.json` | Plugin hook registration (session-start sync + event-driven refresh) |
| `commands/refresh.md` | `/zai-quota:refresh` — force one fetch from the CLI |
| `scripts/quota-fetch.sh` | Single GET to the Z.AI usage endpoint, response-shape validation, atomic cache write |
| `scripts/quota-hook.sh` | Hook wrapper: async-safe, atomic lock, event-aware dedup, log + rotation |
| `scripts/zai-statusline.sh` | Statusline renderer: model chip, 5h/7d bars, context-left, cost |

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
