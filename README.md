# zai-quota-statusline

Event-driven Z.AI / GLM quota monitoring for [Claude Code](https://claude.com/claude-code) —
**no cron, no fixed timers, no polling**. The quota cache refreshes the moment you submit a
prompt and again when the turn finishes, so the statusline always shows fresh numbers.

**Design goal:** the line should feel *native to Claude Code*. Everything lives in the CLI
you already work in — a model chip with a usage-colored dot, usage bars in Claude's own
brand palette (green → orange → red; exact hexes on truecolor terminals), context-left and
session cost — visible in real time, with no manual refresh requests and no browser
dashboard.

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
| `ZAI_SB_SEGMENTS` | `10` | Bar length in cells |
| `ZAI_SB_AGE` | `0` | `1` = append cache-age (`· 5m`) to the line |
| `ZAI_SB_PLAIN` | `0` | `1` = plain glyphs, no Nerd Font required |
| `ZAI_SB_CACHE` | `~/.claude/zaiquota/quota.cache` | Cache file location |

## Files

| File | Role |
|---|---|
| `hooks/hooks.json` | Plugin hook registration (session-start sync + event-driven refresh) |
| `commands/refresh.md` | `/zai-quota:refresh` — force one fetch from the CLI |
| `scripts/quota-fetch.sh` | Single GET to the Z.AI usage endpoint, atomic cache write |
| `scripts/quota-hook.sh` | Hook wrapper: async-safe, `flock`, event-aware dedup, log + rotation |
| `scripts/zai-statusline.sh` | Statusline renderer: model chip, 5h/7d bars, context-left, cost |

## License

MIT — see [LICENSE](LICENSE).
