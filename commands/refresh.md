---
description: Refresh the Z.AI quota cache now (single fetch, no AI)
allowed-tools: Bash(bash ${ZAI_QUOTA_DIR:-$HOME/.claude/zaiquota}/quota-fetch.sh --force)
---

!`bash ${ZAI_QUOTA_DIR:-$HOME/.claude/zaiquota}/quota-fetch.sh --force`

Reply with the command output above only — one line, no analysis. If it contains "ERROR", append one hint: check `config.env` in your `ZAI_QUOTA_DIR` (default `~/.claude/zaiquota`).
