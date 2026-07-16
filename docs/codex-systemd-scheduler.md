# Codex systemd user scheduler

This document owns the managed scheduler evidence and adapter contract for Codex bounded checkpoint supervision on WSL/Linux.
The implementation lives in `bin/fm-codex-systemd-scheduler.sh`.

## Contract

Codex primary supervision may use one FirstMate-owned `systemd --user` timer for the canonical `FM_HOME`.
The adapter derives one deterministic service name and one deterministic timer name from the canonical home path and Unix UID.
The service runs `bin/fm-watch-checkpoint.sh --seconds <cadence>` with explicit `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_SUPERVISION_HARNESS=codex`, generation, lease, and cadence environment.
The timer is registered through `systemctl --user`, not through shell backgrounding or a detached unmanaged process.
Health is never proven by the JSON schedule record alone.
`bin/fm-supervision-lib.sh` treats `healthy-checkpoint-scheduled` as valid only when the record's owner matches a live verified primary (the session lock's live holder pid bound to its process identity, home, UID, and durable codex harness record), every field validates individually, and the scheduler adapter's read-back of the LOADED timer/service contract agrees: exact `ExecStart`, environment lease/generation/cadence lines, linked service, enabled plus active state, the timer's real next trigger against the record due time, and no duplicate unit claiming the home.
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

The deterministic day-to-day coverage of the same real-mode branch (generated unit content, altered `ExecStart`, disabled timer, missing timer, next-elapse disagreement, trigger mismatch, duplicate units, and the directive-injection refusals) lives in `tests/fm-codex-systemd-scheduler.test.sh`, driven through a stub `systemctl` and a scratch unit directory under the test-seam gate.
