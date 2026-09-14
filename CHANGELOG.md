# Changelog

## 0.1.8 — 2026-09-14
Fourth-pass audit fixes. Session-start sync installs scripts atomically
(copy to a process-unique temp name, rename into place — a reader can
never run a half-written script) via the new `scripts/sync.sh`. The
release workflow now runs the smoke suite and manifest validation before
publishing, and the Claude Code CLI used by CI is pinned to 2.1.270 for
reproducibility. Statusline labels the 5h/7d windows by the limits'
`number` field when available, so a weekly reset happening sooner than
the 5-hour one no longer swaps the labels. `ZAI_QUOTA_DIR` overrides the
base directory. README lock description updated; skipped tests fail CI
explicitly so coverage can't silently shrink.

## 0.1.7 — 2026-09-14
Close the last lock TOCTOU. The lock is now a symlink whose target is the
holder's PID: claim and PID publication happen in the same atomic
symlink(2) call, so a contender can never observe a claimed-but-unstamped
lock — the 300 ms re-check window of 0.1.6 is gone entirely. The
pre-0.1.7 directory format is still honored and reclaimed. A six-way
parallel stress run yields exactly one fetch; regression tests cover the
symlink format, the legacy directory format, and dead-holder reclaim.

## 0.1.6 — 2026-09-14
Fix the fetch lock's mutual exclusion (third audit pass). The 0.1.5
timestamp-named lock let processes starting in different seconds fetch in
parallel — the mutex identity was broken. The lock is now a fixed-name
directory holding the holder's PID: contenders skip while that PID is
alive and reclaim when it is gone (a brief re-check covers the
claim/stamp window of a crashed claim). Legacy lock formats are absorbed
by the same path. Regression tests cover the three behaviors that matter:
a live lock skips, a dead lock is reclaimed, concurrent starts fetch
exactly once.

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
