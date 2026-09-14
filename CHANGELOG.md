# Changelog

## 0.1.12 — 2026-09-14
Close issue #1: the base-directory default now follows a relocated Claude
config. Every entry point (hook registrations, `/zai-quota:refresh`, the
statusline's cache path, sync/fetch/hook internals) resolves
`${ZAI_QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zaiquota}` — an explicit
`ZAI_QUOTA_DIR` still wins; otherwise the directory follows `CLAUDE_CONFIG_DIR`;
otherwise `~/.claude/zaiquota`. Existing `CLAUDE_CONFIG_DIR` users: move the
directory once (`mv ~/.claude/zaiquota "$CLAUDE_CONFIG_DIR/zaiquota"`) — the
README says so up front, per the plain-precedence decision on the issue.
The wiring guard now asserts the full chain in all six entry points plus a
functional precedence check (`ZAI_QUOTA_DIR` > `CLAUDE_CONFIG_DIR`), and the
hook/fetch/security tests neutralize a developer's exported
`CLAUDE_CONFIG_DIR`/`ZAI_QUOTA_DIR` so local env can't skew results. Also:
silence SC2317 on the indirectly-invoked `sb` test helper — shellcheck ≥0.9
(which our pinned 0.8.0 predates) flags it as unreachable, which is what turned
the v0.1.3/v0.1.8 tag builds red.

Native-feel bonus: the chip's dot now **breathes while a turn is live**. The
stdin JSON carries no busy signal, so the hooks provide one — `pre` stamps a
per-session `.turn-<session_id>` flag at prompt submit, `post` clears it at
turn end, `session` sweeps leftovers from crashed turns — and the statusline
renders the dot SGR-dimmed on even seconds: a 1 Hz intensity pulse, the
smoothest cadence the statusline host can drive (`statusLine.refreshInterval`,
min 1 s; event-driven re-renders add irregular extra steps for free). The flag
is a file stamp and adds no API calls; README snippets gain
`"refreshInterval": 1` and spell out that fetching stays event-driven.

## 0.1.11 — 2026-09-14
Fix inverted severity colors: the status line now uses xterm-256 cube palette
codes (65 / 173 / 131) exclusively instead of free-form truecolor. Diagnosed
with a pixel-level calibration strip: some TUI statusline render paths
quantize truecolor to the 6x6x6 cube (each channel via round(c/51)), and that
rounding pushed the ≥80% red's green channel up (77→135) until it rendered
brighter and warmer than the 50–79% orange — red and orange visually swapped.
On-cube colors are identity-mapped by such quantizers, so severity now reads
correctly everywhere. Documented in the README.

## 0.1.10 — 2026-09-14
Statusline readability fix: remaining-time tokens separate their unit groups
with a space — `2h 45m`, `1d 4h` — instead of the glued `2h45m`/`1d4h`.
Single-unit values (`12m`) are unchanged. Covered by a regression test.

## 0.1.9 — 2026-09-14
Close the fifth-audit finding: `ZAI_QUOTA_DIR` is now honored end-to-end, not
just by the scripts' internals. The hook registrations, the statusline's
default cache path and `/zai-quota:refresh` all resolve the base directory via
`${ZAI_QUOTA_DIR:-$HOME/.claude/zaiquota}`, so an override can no longer split
code (installed dir) from data (default dir) and leave the statusline at
"quota n/a". README documents the override as a first-class option (export it
so hooks and the statusline inherit it, point `statusLine.command` at the same
directory), and the test suite guards the wiring: every path into the stable
directory must sit inside a `${ZAI_QUOTA_DIR:-...}` fallback, plus a functional
check that the statusline reads a cache placed under an overridden directory.
CI now verifies the pinned shellcheck tarball's sha256 before installing it.

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
