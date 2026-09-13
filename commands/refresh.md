---
description: Refresh the Z.AI quota cache now (single fetch, no AI)
allowed-tools: Bash(bash $HOME/.claude/zaiquota/quota-fetch.sh --force)
---

!`bash $HOME/.claude/zaiquota/quota-fetch.sh --force`

Report the result in one short line. If the fetch failed, include the error output and remind the user to check `$HOME/.claude/zaiquota/config.env`.
