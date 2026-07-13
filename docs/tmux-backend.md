# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, Orca, or cmux) - it is the fully verified reference path for secondmate homes, while Orca and cmux are the backends that do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Endpoint liveness evidence

On 2026-07-05, tmux `display-message` was verified unsuitable as a task-window existence probe because a missing window in an existing session resolved to the session's active pane.

Command:

```sh
tmux -V
```

Output:

```text
tmux 3.6
```

Command:

```sh
tmux new-session -d -s fm-ghost-evidence-g1 -n active
```

Output:

```text
<no output, exit 0>
```

Command:

```sh
tmux display-message -p -t 'fm-ghost-evidence-g1:fm-does-not-exist' '#{pane_id}'
```

Output:

```text
%9
```

Exit status: `0`.

The structural window inventory did not contain that missing target.

Command:

```sh
bash -c "tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -qx 'fm-ghost-evidence-g1:fm-does-not-exist'"
```

Output:

```text
<no output>
```

Exit status: `1`.

After the fix, `fm_backend_target_exists` used the window inventory and returned the expected verdicts for the same temporary session.

Command:

```sh
bash -c '. bin/fm-backend.sh; if fm_backend_target_exists tmux "fm-ghost-evidence-g1:fm-does-not-exist" "fm-does-not-exist"; then printf "missing=alive\n"; else printf "missing=dead\n"; fi; if fm_backend_target_exists tmux "fm-ghost-evidence-g1:active" "active"; then printf "active=alive\n"; else printf "active=dead\n"; fi; if fm_backend_target_exists tmux "active" "active"; then printf "bare-active=alive\n"; else printf "bare-active=dead\n"; fi'
```

Output:

```text
missing=dead
active=alive
bare-active=alive
```

## Incident (2026-07-13): false "Enter swallowed" on claude's `❯` + U+00A0 composer

`bin/fm-send.sh` reported `error: text not submitted ... (Enter swallowed; text left in composer)` and exited non-zero on messages the crew had actually received and answered - at least five times in one day, on long and short messages alike.
The delivery path was never broken; the SUBMIT VERIFICATION was a false negative, so firstmate took recovery actions for steers that had already landed.

**Root cause.**
A submit is confirmed by reading the composer back as empty.
The claude build in use draws its idle composer as the prompt glyph `❯` (U+276F) between two U+2500 rules, and pads the rest of that row with a single U+00A0 NO-BREAK SPACE (captured with `tmux capture-pane` + `cat -A`: `M-bM-^]M-/` then `M-BM- `) - no `│ > … │` box at all.
U+00A0 is not ASCII whitespace and does not match `[[:space:]]`, so the row trimmed to `❯<U+00A0>` rather than `❯`, never matched the bare-agent-glyph case in the shared classifier, and read as `pending`: real, unsubmitted text.

**Fix.**
`bin/fm-composer-lib.sh`, the one fleet-wide owner, now folds non-breaking spaces (U+00A0, U+202F) to ASCII spaces before any trim or emptiness test (`fm_composer_trim_into`), and every trim on the tmux composer path routes through it.
This changes only what counts as WHITESPACE, never what counts as a composer: a bare shell prompt still reads `unknown` (the away-mode injection safety rule), and real typed text still reads `pending`, so `fm-send` stays fail-closed on a genuinely unsubmitted message.
The away-mode daemon shares the same primitive, so its own submit confirmation - and the spurious wedge alarm a failed confirmation raises - is fixed by the same change.

**Duplicate-submit guard.**
Because the retry loop presses Enter until the composer clears, an unconfirmable submit used to mean blind Enters at a composer that no longer held our text.
`fm_tmux_submit_core` now snapshots the composer content right after typing, and `fm_tmux_submit_enter_core` re-presses Enter only while the row still holds exactly that content; the moment it differs, the loop stops and reports `unknown` (fm-send treats that as delivered, the daemon as unconfirmed).
An Enter retry can therefore never produce a second turn.

Regression coverage: `tests/fm-composer-lib.test.sh` (the U+00A0 verdicts, written as escapes), `tests/fm-send-submit-verify.test.sh` (submit confirmation, fail-closed swallow, the duplicate-submit guard), and `tests/fm-send-claude-composer-e2e.test.sh` (real `bin/fm-send.sh` over a real tmux pane drawing the captured shape: exit 0, delivered exactly once).

## Limitations

None specific to tmux for the reference path itself - it is the fully verified reference backend, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above has one known gap (`pi`'s generic `node` process name, see above).
