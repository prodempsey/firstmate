# Codex systemd user scheduler

This document owns the managed scheduler evidence and adapter contract for Codex bounded checkpoint supervision on WSL/Linux.
The implementation lives in `bin/fm-codex-systemd-scheduler.sh`.

## Contract

Codex primary supervision may use one FirstMate-owned `systemd --user` timer for the canonical `FM_HOME`.
The adapter derives one deterministic service name and one deterministic timer name from the canonical home path and Unix UID.
The service runs `bin/fm-watch-checkpoint.sh --seconds <cadence>` with explicit `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_SUPERVISION_HARNESS=codex`, generation, lease, and cadence environment.
The timer is registered through `systemctl --user`, not through shell backgrounding or a detached unmanaged process.
Health is never proven by the JSON schedule record alone.
`bin/fm-supervision-lib.sh` treats `healthy-checkpoint-scheduled` as valid only when the record's owner matches a live verified primary (the session lock's live holder pid bound to its process identity, home, UID, and durable codex harness record), every field validates individually, and the scheduler adapter's read-back of the LOADED timer/service contract agrees per the loaded-contract validation section below: exact fragment paths with no drop-ins, exact `ExecStart`, the exact controlled environment with no indirection, linked service, enabled plus active state, the timer's real next trigger against the record due time, and no duplicate unit claiming the home.
The record's `integrity` field is a sha256 corruption checksum only, never an authenticity control: any same-account writer can recompute it, so it detects truncation and accidental edits, not forgery.

## Trust boundary

The operational boundary is the Unix account.
Everything under `state/` - the schedule record, the durable harness record, the running-checkpoint lease - is writable by every process running as the account owner, including every crewmate and hook, and the user systemd manager itself runs as that same account.
The contract therefore defends the health verdict against accidents, stale sessions, wrong homes, and ambient environment pollution; it does not and cannot defend against a hostile process already running as the same account.
What the live-primary binding guarantees is that no combination of written files alone - with no live, verified primary session owning them - ever reads as healthy supervision.

## Test seams (fail closed)

`FM_CODEX_SYSTEMD_FAKE_DIR` (fake registration mode), `FM_CODEX_SYSTEMD_SYSTEMCTL` (stub systemctl), and `FM_CODEX_SYSTEMD_UNIT_DIR` (scratch unit directory) are test seams, honored only when ALL of the following hold: `FM_SUPERVISION_TEST_MODE=1`, the evaluated home and state dir sit under a root carrying the `.fm-test-owner` marker written by `tests/lib.sh`, the overridden directories are test-owned the same way, and nothing points inside the real user unit directory.
Any seam set without that full gate makes every adapter command fail closed with exit 2 and a `test-override-*` reason - production never falls back to fake mode, real mode, or a substituted query.
A stub systemctl additionally requires an explicit test-owned unit directory so stub-driven tests can never write into the real user manager's directory.

## Record-field validation

Every record field that can reach a unit file is charset-allowlisted before unit generation, because systemd unit files are line-oriented and an embedded newline starts an attacker-chosen directive: leases match `[A-Za-z0-9._-]{1,128}`, numeric fields are bounded digit strings, and paths must be absolute with no control characters, quotes, backslashes, or percent specifiers.
The `ExecStart` command line is constructed only from the adapter's own computed metadata plus the validated numeric cadence; free-form record text never reaches it.
Unit files and the fake registration are written with mode 0600.
`WorkingDirectory` is written raw (path directives are not quote-unescaped by systemd; a quoted value is fatally invalid), which the disposable proof below caught: the earlier quoted form could never arm a timer on real systemd.

## Loaded-contract validation (review-r4)

Expected-line presence is never validation authority.
A loaded service can carry every expected line and still be overridden by a later directive, a drop-in, `EnvironmentFile=`, or `UnsetEnvironment=`: per `systemd.exec(5)`, a later `Environment=` assignment wins, `EnvironmentFile=` overrides `Environment=`, and `UnsetEnvironment=` is applied as a final removal.
`validate` therefore reads two views and requires BOTH to match the expected contract exactly: systemd's merged effective view (`systemctl --user show`) catches loaded state that diverged from the visible file, and the loaded source (`systemctl --user cat`) catches duplicate assignments the effective view collapses to a single last value.

The exact requirements are:

- exact service and timer `FragmentPath`, and empty `DropInPaths` on both units;
- effective `WorkingDirectory` equal to the canonical home, plus exactly one matching source directive;
- an effective environment of exactly the six controlled variables (`FM_HOME`, `FM_STATE_OVERRIDE`, `FM_SUPERVISION_HARNESS`, `FM_CODEX_SYSTEMD_LEASE`, `FM_CODEX_SYSTEMD_GENERATION`, `FM_CODEX_WATCH_CHECKPOINT`), each with its expected value, none missing, none unexpected;
- exactly one source `Environment=` assignment per controlled variable, so same-value and conflicting duplicates both fail;
- no environment indirection or removal in either view: `EnvironmentFile=` (optional or not), `UnsetEnvironment=`, and `PassEnvironment=` all fail validation;
- exactly one `ExecStart`, matched byte-for-byte in the source and against the effective `{ path=... ; argv[]=... }` command;
- exactly one source `OnCalendar=` on the timer.

Any property-query failure, missing always-printed property, duplicated property line, unexpected output line, or unparseable effective environment fails closed with a stable deterministic reason (`service-property-query-failed`, `service-property-missing:<prop>`, `environment-parse-ambiguous`, `env-duplicate:<name>`, ...).
The effective-view parser splits only systemd's own reported values against a fixed grammar; record text never reaches parser syntax, and nothing is ever evaluated.

Empirical `systemctl show` formats (systemd 259, 2026-07-16, verified by the disposable proof below): `Environment=` reports the merged environment with whole-entry quoting for values containing spaces; `EnvironmentFiles=` and `ExecStart=` lines are omitted when empty while the other queried properties print even when empty; `ExecStart` reports `{ path=<argv0> ; argv[]=<command> ; ignore_errors=... }`.

## Disposable Timer Proof (adapter-generated units)

Date: 2026-07-16.
Host: WSL2 Linux `LUD-WORKSTATION 6.6.114.1-microsoft-standard-WSL2`.
User and UID: `prode`, `1000`.
Systemctl path: `/usr/bin/systemctl`.
User manager state: `running`.
Proof home: `/tmp/fm-codex-proof-home.20260716133833-2081533.J2FcxL` (uniquely named scratch home; unit names hash the home path, so the proof units can never collide with a live fleet home's units).
Proof unit: `fm-codex-checkpoint-b859e2816c129223`.

Command class run: in PRODUCTION mode (no test seams set), with the proof shell itself as the live session-lock holder, the shipping `fm_supervision_persist_primary_harness`, `fm_codex_checkpoint_prepare`, and `fm_codex_checkpoint_finish` path armed the adapter-generated service/timer pair through `systemctl --user`, the registration was read back, `validate` and `fm_supervision_health` were evaluated, the timer was tamper-disabled, and the adapter `remove` verb tore everything down.

Observed registration read-back:

```text
timer Triggers=fm-codex-checkpoint-b859e2816c129223.service
timer LoadState=loaded
timer ActiveState=active
timer UnitFileState=enabled
timer NextElapseUSecRealtime=Thu 2026-07-16 13:43:34 EDT (cadence 300s from finish)
service LoadState=loaded
loaded ExecStart=<repo>/bin/fm-watch-checkpoint.sh --seconds 300
```

Observed production validation and health:

```text
validate: true (valid)
health: healthy-checkpoint-scheduled (checkpoint-scheduled) in_flight=1
```

Observed tamper detection:

```text
systemctl --user disable --now <timer>
validate-after-disable: false (timer-not-active timer-not-enabled)
```

Observed cleanup:

```text
service file absent: yes
timer file absent: yes
list-unit-files match empty: 0
list-timers match empty: 0
timer LoadState: not-found
proof home removed: yes
PROOF_RESULT=PASS unit=fm-codex-checkpoint-b859e2816c129223
```

## Disposable loaded-contract proof (review-r4 validation)

Date: 2026-07-16.
Host, user, systemctl: same as above; systemd 259 (259.5-0ubuntu3), user manager `running`.
Proof home: `/tmp/fm-codex-proof-r4-home.20260716175926-3005523.ClPrsT` (uniquely named scratch home).
Proof unit: `fm-codex-checkpoint-4710c57420d17ed2`.

Command class run: in PRODUCTION mode (no test seams), the adapter armed its generated service/timer pair, `validate` was evaluated pristine and after two loaded-contract tampers applied with `systemctl --user daemon-reload`, and the adapter `remove` verb tore everything down.

```text
pristine validate: {"ok":true,"reason":"valid",...}
append Environment="FM_HOME=<evil>" -> {"ok":false,"reason":"home-env-mismatch env-line-count-mismatch env-duplicate:FM_HOME",...}
drop-in with Environment="FM_CODEX_EXTRA=1" -> {"ok":false,"reason":"service-drop-in env-unexpected:FM_CODEX_EXTRA env-line-count-mismatch",...}
service file absent: yes / timer file absent: yes / drop-in dir absent: yes
list-unit-files matches: 0 / list-timers matches: 0 / timer LoadState: not-found
stray production units: 0 / proof home removed: yes
PROOF_RESULT=PASS unit=fm-codex-checkpoint-4710c57420d17ed2
```

The observed pristine effective properties confirmed the parser's format assumptions: merged `Environment=` (duplicate collapsed to its last value), `EnvironmentFiles=` omitted when empty, and the `{ path=... ; argv[]=... ; ignore_errors=no ; ... }` `ExecStart` block.

The deterministic day-to-day coverage of the same real-mode branch (generated unit content, altered `ExecStart`, disabled timer, missing timer, next-elapse disagreement, trigger mismatch, duplicate units, duplicate and conflicting controlled assignments, environment indirection and removal, wrong working directory, service and timer drop-ins, unexpected and missing variables, effective-versus-source divergence, failed or unanswered or malformed property queries, and the directive-injection refusals) lives in `tests/fm-codex-systemd-scheduler.test.sh`, driven through a stub `systemctl` that emulates systemd's effective-property semantics and a scratch unit directory under the test-seam gate.
