# Crew-session broad-kill PreToolUse seatbelt

This document is the authoritative human-readable contract for the crew-session
kill-pattern guard.
`bin/fm-crew-kill-pretool-check.sh` is the single owner of both the transport
and the classification; there is no separate policy process for this guard.

## Incident evidence

`data/cockpit-crash-triage-x1/report.md` (bug-20260712002638-66d9ce63) traced
every recent live fleet-bridge cockpit crash to the same root cause: a
crewmate's own test/verification cleanup running an unscoped process-name
kill that also matched the LIVE cockpit server or the REAL tmux server.
Confirmed, second-exact, transcript-to-journal correlation:

| Crew | Command | Effect |
| --- | --- | --- |
| fleet-bridge-fbfd4c/3 | `pkill -f "node server.js"` | cockpit bounce; pre-fix, the whole tmux server (console + every crew) was wiped |
| fleet-bridge-fbfd4c/6 | `pkill -f "node server.js"` | same class; captain filed ORD-005 after the mass respawn |
| fleet-bridge-fbfd4c/4 | `pkill -9 -f "node.*server.js"` | post-fix: tmux survived, but node + ttyd were SIGKILLed |
| fleet-bridge-fbfd4c/4 | `pkill -9 -f "node server.js"` | same |

A near-miss class is also on record: a firstmate-repo crew ran bare
`tmux kill-server` (no `-L <socket>`) on 2026-07-10, which would have killed
the REAL tmux server directly had it been reached with a live server present.

## Purpose and boundary

A crewmate's own cleanup (killing a test server it spawned, tearing down a
scratch tmux session) is legitimate and common.
The failure mode is not doing cleanup - it is doing it with a **pattern** or a
**bare command** broad enough to also match the live cockpit server or the
shared tmux server that hosts the captain's console and every other crew's
pane.
This guard denies that class of command before it runs, in crew sessions
only; it says nothing about the firstmate primary's own supervision commands,
which `bin/fm-arm-pretool-check.sh` already protects.

## Deny rules

| Code | Denies | Safe alternative |
| --- | --- | --- |
| `crew-broad-kill` | `pkill`/`killall` (any flags) whose pattern contains, case-insensitively, `server.js`, `fleet-bridge`, `ttyd`, or `tmux` | `kill <pid>` on the exact PID you spawned (a recorded `$!`) |
| `crew-broad-kill` | `kill` fed from a `pgrep -f` of one of those same names, in either byte order (`kill -9 $(pgrep -f ...)`, `pgrep -f ... \| xargs kill -9`) | same |
| `crew-tmux-kill-server` | `tmux kill-server` with no explicit `-L`/`-S` socket argument | `tmux -L <your-test-socket> kill-server` |
| `crew-systemctl-fleet-bridge` | `systemctl --user restart\|stop\|kill fleet-bridge` | crew sessions never manage the live unit at all |

The four real incident commands above, and the recorded near-miss, are exact
regression cases in `tests/fm-crew-kill-pretool-check.test.sh`.

## Allow rules

- A pure `echo`/`printf` of a literal string is data, not an executed kill,
  the same "quoted text is data" principle `bin/fm-arm-pretool-check.sh`'s
  classifier documents (e.g. `echo 'pkill -f fleet-bridge'` in a log message
  or a doc-search command). This allowance stops at anything chained after
  the `echo`/`printf` (`;`, `&&`, `||`, `|`, a newline) and at any command
  substitution or backtick, so a real kill cannot smuggle itself in as the
  printed argument.
- Any command with no kill-shaped verb (`pkill`, `killall`, `kill-server`,
  `systemctl`, or a `pgrep`+`kill` pair) at all is a fast allow; this
  classifier never inspects a command it has no reason to.
- A bare `kill <pid>` with no `pgrep` anywhere in the command is always
  allowed - the guard only ever denies a pattern-fed kill, never a plain PID
  kill, which is exactly the safe form the deny messages point crews at.
- A standalone read-only `pgrep` (no `kill` in the same command) is allowed.
- A `pkill`/`killall` pattern, or a `pgrep`+`kill` pair, that names a path
  this crew is known to own is allowed even if it also mentions one of the
  banned names above: an explicit `--sandbox <path>` root passed to the
  checker (fm-spawn.sh bakes in the crew's own worktree and per-task tmp
  root), the generic `/tmp/fm-` per-task tmp prefix every crew uses, or a
  path containing `sandbox` or `scratchpad`.
- Any tmux operation - `kill-server` or otherwise - that carries an explicit
  `-L <socket>` or `-S <path>` argument is allowed: that names a specific,
  non-default socket rather than the shared default server the captain's
  console and every crew pane run on.

Deliberately NOT allow-listed: a pattern that merely adds an extra
discriminator word to a banned name (e.g. `"node server.js.*some-other-token"`)
without being sandbox- or socket-scoped.
One incident crew got away with exactly this once by coincidence (the extra
token happened not to appear in the live server's argv), then dropped the
extra token on its very next cleanup kill and hit the live server.
Pattern-matching "sufficiently specific" regexes is not a safety property;
PID-exact kill of a self-spawned process is, so the guard pushes crews there
instead of rewarding a cleverer regex.

## Transport and harness wiring

The transport mirrors `bin/fm-arm-pretool-check.sh` exactly: stdin JSON at
`.tool_input.command` (Claude/Codex) or `.toolInput.command` (Grok),
`--command <exact string>` for CLI-driven adapters, `--claude` to keep
Claude's stderr-only deny requirement, and the same fail-open posture on
missing/malformed stdin or missing `jq`.
Deny writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[code] reason"}`
to stderr, plus a Grok-shaped `{"decision":"deny","reason":"..."}` on stdout
unless `--claude` was passed; allow is silent on both streams, exit 0.

**Harness coverage today is Claude-only.** `bin/fm-spawn.sh` writes a
worktree-local `.claude/settings.local.json` for every non-secondmate
Claude-harness crewmate task, and that is the only crew-session settings file
fm-spawn.sh currently installs at all - Codex, Grok, OpenCode, and Pi
crewmates get only their per-harness turn-end hook (see `bin/fm-spawn.sh`'s
per-harness case), not a worktree-local PreToolUse guard, because no
mechanism to install one for those harnesses' crew sessions exists yet.
Extending coverage to another harness means adding that harness's own
crew-session hook file to `bin/fm-spawn.sh`, the same way its turn-end hook
was added.

For a Claude crewmate, fm-spawn.sh installs:

```json
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '<TURNEND>'"}]}]},"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"<checker> --claude --sandbox <worktree> --sandbox <task-tmp>"}]}]}
```

`<checker>` is an absolute path to `bin/fm-crew-kill-pretool-check.sh` in the
firstmate root that spawned the crewmate (a cross-repo absolute reference,
the same pattern the existing Stop hook and the Grok turn-end hook already
use for paths outside the crewmate's own project worktree).
`<worktree>` and `<task-tmp>` are this crew's own worktree path and its
`/tmp/fm-<id>` task tmp root, passed as `--sandbox` roots so this crew's own
scratch test fixtures never trip the guard.

## Brief-contract rule

`bin/fm-brief.sh`'s ship and scout scaffolds both add a rule requiring
PID-exact kills of self-spawned processes and socket-scoped tmux teardown,
never pattern kills - the same requirement this guard enforces mechanically,
stated in the brief so a crewmate on a harness this guard does not yet cover
still gets the instruction.

## Automated validation

`tests/fm-crew-kill-pretool-check.test.sh` covers the four real incident
commands and the recorded near-miss as exact deny regressions, the allowed
scoped forms (sandbox path, `-L`/`-S` socket), the `-L` tmux distinction, the
fail-open transport paths, the `--claude` output-shaping contract, and the
`fm-spawn.sh` wiring into a Claude crewmate's `.claude/settings.local.json`.

Run:

```sh
bash -n bin/fm-crew-kill-pretool-check.sh
shellcheck bin/fm-crew-kill-pretool-check.sh tests/fm-crew-kill-pretool-check.test.sh
tests/fm-crew-kill-pretool-check.test.sh
```
