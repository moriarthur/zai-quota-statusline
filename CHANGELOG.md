# Changelog

## 0.1.5 — 2026-09-14
Second-pass audit fixes. Model names coming from the
`ANTHROPIC_DEFAULT_*_MODEL` mapping and settings env blocks now pass the
same ANSI/control filters as display names (sanitization runs last).
Malformed decimal costs ("1..2") no longer reach printf. The fetch lock
carries its creation timestamp in the directory name, closing the reclaim
race between lock creation and timestamp write; pre-0.1.5 locks are
migrated on first run. The junk-200 fixture test skips cleanly when the
environment cannot bind a test server.

## 0.1.4 — 2026-09-14
Robustness hardening after an external audit. `config.env` is parsed, never
sourced — a tampered file cannot execute code; it must be a regular file
owned by the user and its permissions are auto-tightened to 0600. A junk
HTTP 200 is rejected by response-shape validation (`data.limits` array)
before it can replace a good cache. The statusline strips ANSI/control
characters from model names, caps their width, and sanitizes non-numeric
values instead of emitting shell errors. The fetch lock is now an atomic
`mkdir` with stale-lock reclaim (portable, replaces flock), and temp files
are unique per process, renamed into place atomically. test.sh is
shellcheck-clean and covers the new behavior with offline regression tests
(including a local HTTP fixture server).

## 0.1.3 — 2026-09-14
macOS compatibility. `flock`, `stat -c%s` and `timeout` are GNU/util-linux
tools missing on stock macOS: the hook now degrades gracefully without flock
(the dedup window still guards double-fetches), rotates the log via
`wc -c`, and runs the fetch without the timeout wrapper when it is absent
(`curl --max-time` already bounds the network part). README documents
requirements and platform support.

## 0.1.2 — 2026-09-14
Security hardening. The fetcher refuses plain-http base URLs (the token never
crosses the wire in cleartext); cache, log, lock and state files are created
with `0600` permissions (`umask 077`); temp files are cleaned on every exit
path; API error bodies are truncated; curl gets a hard `--max-time`. Leak-
regression tests in CI (failed fetch must not echo the token, plain-http must
be refused). README documents the security model.

## 0.1.1 — 2026-09-14
`/zai-quota:refresh` pre-approves its single fetch via `allowed-tools` so it
runs without a permission prompt; the reply instruction is tightened to one
line; README gains an ASCII preview of the line.

## 0.1.0 — 2026-09-13
Initial plugin release. Event-driven quota hooks (SessionStart syncs scripts
to a stable path and refreshes; UserPromptSubmit / Stop refresh around each
turn; async, flock + event-aware dedup), native-feeling statusline (Claude
brand palette with truecolor hexes, exact model display with
`ANTHROPIC_DEFAULT_*_MODEL` resolution, context-left, session cost, plain
mode for terminals without a Nerd Font), `/zai-quota:refresh` command,
plugin + marketplace manifests, CI with smoke tests and manifest validation.
