# Changelog

## 0.1.21 — 2026-09-16
The breath quickens to the host's render floor: the dot toggles every beat —
the dim gray for one second, the tier color for the next, a full cycle every
two seconds. The old four-second rhythm held the color twice as long as it
dimmed; now each tone gets exactly one beat, the fastest flicker
`refreshInterval` can draw.

## 0.1.20 — 2026-09-16
The breath settles on two tones: the hueless dim gray (`38;5;240`) and the tier
color — gray, mid, mid, gray, two seconds each. The bright ladder step from the
earlier ramps is gone entirely; the pulse now reads as the dot dimming to its
"off" end and coming back, nothing more.

## 0.1.19 — 2026-09-16
The busy dot's breath is a three-step walk again: a hueless dim gray (`38;5;240`,
the dot reading as switched off), then the tier color, then one ladder step up —
dim, mid, bright, mid, two seconds a step. The mid and bright tones are exactly
the two the previous releases calibrated; only the gray "out" endpoint is new,
so the pulse now visibly leaves and returns to the color instead of hovering
around it.

## 0.1.18 — 2026-09-16
The `quota n/a` some users saw while the 5h window recharged is now self-healing.
Root cause: mid-swap the API answers with a shape-valid but empty `limits` array,
which the fetcher stored over the good cache — and nothing in the render path can
recover from zero windows, so the line froze at n/a until the next prompt. The
fetcher now treats an empty snapshot as transient and leaves the previous cache
untouched (a 200 that says nothing is not an error); and the statusline's self-heal
grew a third trigger — a cache with no usable windows nudges the same throttled
background fetch the rollover path uses, healing caches poisoned by older versions
at one GET per `ZAI_ROLL_MIN` at worst.

## 0.1.17 — 2026-09-16
The stable copy of the scripts finally keeps itself current. Until now it only
synced on session start, and since `/plugin update` and `/reload-plugins` never
re-fire that hook, a mid-session update left users on the previous version —
pill caps, dead dot and all — until a restart or a manual sync. A parity check
(`ensure-current.sh`) now runs from the plugin root on every prompt submit and
turn end, chained with `;` so the quota hook after it always fires, and
re-syncs the stable path in milliseconds when the installed plugin's scripts
have moved ahead; a `sync:` line in `hook.log` records each resync and reports
orphan files, which are never deleted (the stable directory may be a
user-chosen one).

## 0.1.16 — 2026-09-15
Two display calibrations on top of the payload flip. With both windows present
the renamed `CREDIT_LIMIT` payload is the familiar plan pair, so the 5h/7d
labels are back; a lone credit window still renders as a bare bar — its name
is not verifiable. And the busy dot's breath peaks one tone lower now: two
same-hue on-cube tones per tier (green 65↔108, amber 137↔173, red 95↔131),
two seconds each — the previous top step read too bright next to Claude's
own spinner.

## 0.1.15 — 2026-09-15
Same-day follow-up, and the documented risk arrived on schedule: Z.AI
flipped the plan windows in the usage payload from `TOKENS_LIMIT` to
`CREDIT_LIMIT` (observed 2026-09-15). 0.1.14's credit fallback then
rendered a single bar labeled `quota` and hid the weekly window entirely.
The credit payload's `number`/`unit` fields do not map to window durations
(unit 3 with a reset one hour away), so no labels are invented anymore:
both windows render as bare reset-sorted bars — bar, percentage, time to
reset — which is exactly the data the API still guarantees.

## 0.1.14 — 2026-09-15
Startup race, both ends. The session-start fetch usually wins, but Claude Code
can draw the first statusline a moment before the cache lands — and without
`statusLine.refreshInterval` that first `quota n/a` then sat on screen until
the first conversation event (observed on macOS: the hook log showed
`session: force fetch` → `quota cache updated` while the line still read
n/a). The README now presents `refreshInterval: 1` as the required piece (it
is the documented mechanism for periodic statusline re-runs, minimum 1 s),
corrects the install step that promised the fetch always beats the first
render, and gains a Troubleshooting section for "n/a after launch".

The statusline also gained a second, stricter self-heal: when the cache FILE
is absent while `config.env` exists — a session hook that never ran or was
killed — the next render nudges one background `quota-fetch --force`, sharing
the rollover nudge's stamp and `ZAI_ROLL_MIN` throttle. A present-but-
unparsable cache (empty or unsupported quota response) never nudges, and
neither does an install without `config.env`.

The chip sheds its Nerd Font pill caps everywhere. Rounded caps were the one
glyph-dependent element left — they render as replacement glyphs wherever the
font is missing (macOS was already auto-switched, but IDE terminals, SSH boxes
and fresh Linux installs were a coin toss). The chip is now the plain
`● model` on every platform, CLI and IDE alike; `ZAI_SB_PLAIN` and the Darwin
detection that picked the chip form are gone with it.

The busy dot's breath is rebuilt. The old "2 Hz" SGR-2 toggle never actually
toggled — the render clock has whole-second resolution, so `(tick / 500) % 2`
was always 0 and busy dots sat statically faint — and SGR faint is exactly
the attribute some render paths drop. The dot now breathes through three
same-hue on-cube luma steps per usage tier (green 65/108/151, amber
137/173/216, red 95/131/174) — dim, mid, bright, mid, one step per second: a
calm 4-second cycle at the statusline host's 1 Hz render floor. Idle stays
static; `ZAI_SB_TEST_TICK` now freezes the clock in whole seconds.

The context-left number stopped flashing 100%. Claude Code's statusline
payload computes remaining = 100 − used in one expression, but its builder
has no zero-usage guard (the /context path does): a transient placeholder
usage once arrived as used_percentage: 0 and flashed "context left 100%"
across a few renders — observed live as 89 → 100 → 88. The statusline now
reads only used_percentage (one source is enough when the pair is computed
together) and holds a rise of ≥ `ZAI_SB_CTX_JUMP` points (default 10) until
it repeats on two consecutive identical frames — per-session state, stale
after 300 s. Falls and smaller rises show immediately, the chip color
follows the displayed value, and a real compaction lands about two seconds
late instead of never. `ZAI_SB_DEBUG=1` (off by default) appends one line
per incident — held jumps and displayed changes only, never steady renders —
to a user-private `statusline-debug.log`, rotated like hook.log.

The session cost got honest edges. `cost.total_cost_usd` is Claude Code's
own list-price estimate for the session (reset by /clear), not the Z.AI
invoice — the README now says so. A non-numeric or negative value hides the
cost segment instead of posing as a believable $0.00, scientific notation
parses properly (strtod via printf, exit code as the validator), and the
render is locale-locked to C so a ru-RU terminal cannot turn $5.10 into
"5,10". A genuinely tiny cost still renders as $0.00 — correct rounding,
not a bug.

Startup is network-proof. SessionStart used to run the first quota fetch
synchronously: a stalled network could hold Claude Code's startup for up to
the 20 s hook timeout. Startup now only runs the fast blocking script sync;
the first fetch fires in the background, and the missing-cache self-heal
plus `refreshInterval: 1` repaint the line when it lands. The self-heal
defers to an in-flight hook fetch, so a cold start fires one fetch; if the
hook process died after writing its dedup state but before fetching,
`quota n/a` can persist for up to `ZAI_ROLL_MIN` seconds (a minute by
default) while renders continue.

Sessions stopped stepping on each other. The session-start state sweep
deleted every `.turn*`/`.ctx*` file — including live parallel sessions'
pulse flags and hysteresis state. It is now age-aware: files newer than
24 h (the readers' own cap) survive; genuinely stale or malformed ones go.

The statusline nudge (rollover + missing-cache) claims an atomic PID-symlink
before spawning — the same idiom as the fetch lock — so two parallel renders
(two Claude windows on one project) can no longer double-spawn the fetch,
defers to an in-flight hook fetch, and routes its own spawn through the hook
wrapper: lock, event dedup and hook.log visibility included. A cold-start
race between the async session hook and the first render now resolves to
exactly one fetch. Hysteresis state is written the same way the cache is:
temp file + rename, so a parallel render or the sweep never reads a torn
file. `ZAI_SB_CACHE` is documented as a read-path override — fetches always
write the standard `<base>/quota.cache`.

Credit-only plans read `quota`, not `5h`: the CREDIT_LIMIT fallback kept
hard-coded 5h/7d labels, which are simply wrong for plans without token
windows (a second credit window is hidden too — it has no weekly meaning).

README wording caught up with the code: "no quota polling" (the optional 1 s
timer re-renders from the cache and never fetches), "no Nerd Font
prerequisite" (the ●/━/─ glyphs ship with stock terminal fonts), python3 on
macOS described as CLT-or-brew rather than a guarantee, and the Z.AI quota
endpoint documented as an internal Coding Plan API built from the base
URL's origin only — a path in `ANTHROPIC_BASE_URL` is ignored for quota.

## 0.1.13 — 2026-09-15
macOS round. The model chip's Nerd Font pill caps (U+E0B6/U+E0B4) render as
replacement glyphs in macOS Terminal, so Darwin now draws the plain "● model"
chip — the same form `ZAI_SB_PLAIN=1` opts into: usage-colored dot, busy-turn
breath and everything else included — while every other platform keeps the pill
untouched. The model-name sanitizer also drops the GNU-only sed flag (`s///I`)
that BSD sed rejects; a rejected sed blanked the whole model pipeline, leaving
stock macOS at a permanent "Claude".

`jq` is no longer a hard dependency: the plugin now bundles `jqsh`, a small
interpreter for exactly the jq subset its scripts use, and every jq call falls
back to it (run by `python3`, which macOS provides with the Command Line
Tools) when jq is absent. `quota-fetch.sh` fails with an actionable message
only when neither jq nor python3 exists — and it fails before spending the
network call. The suite now pins the fallback byte-for-byte: every filter the
scripts use must produce jq-identical output and exit codes through both
parsers, and the full statusline must render identically with jq stripped
from PATH.

Self-healing window rollover. The hooks refresh on prompts and turn ends, so
a 5h/7d boundary passing in between left the bars frozen on the expired
window ("99% … 0m") until the next prompt. The statusline now notices a reset
time in the past on its next render and spawns one `quota-fetch --force` in
the background, throttled by a stamp next to the cache to one attempt per
`ZAI_ROLL_MIN` seconds (default 60). The fresh cache carries the new windows
and the nudge switches itself off.

Also in this release: the session-start hook runs synchronously, so the first
statusline render already has quota data instead of an initial `quota n/a`
(prompt/turn hooks stay asynchronous), and the busy dot breathes at 2 Hz
(500 ms toggle) to sit closer to Claude's own spinner cadence.

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
