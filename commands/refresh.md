---
description: Refresh the Z.AI quota cache now (single fetch, no AI)
allowed-tools: Bash(bash ${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/quota-fetch.sh --force)
---

!`bash ${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}/quota-fetch.sh --force`

Reply with the command output above only — one line, no analysis. If it contains "ERROR", append one hint: check `config.env` in your base directory — `ZAI_QUOTA_DIR`, else `$CLAUDE_CONFIG_DIR/zaiquota`, else `~/.claude/zaiquota`.
