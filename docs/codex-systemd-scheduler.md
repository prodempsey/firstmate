# Codex systemd user scheduler

This document owns the managed scheduler evidence and adapter contract for Codex bounded checkpoint supervision on WSL/Linux.
The implementation lives in `bin/fm-codex-systemd-scheduler.sh`.

## Contract

Codex primary supervision may use one FirstMate-owned `systemd --user` timer for the canonical `FM_HOME`.
The adapter derives one deterministic service name and one deterministic timer name from the canonical home path and Unix UID.
The service runs `bin/fm-watch-checkpoint.sh --seconds <cadence>` with explicit `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_SUPERVISION_HARNESS=codex`, generation, lease, and cadence environment.
The timer is registered through `systemctl --user`, not through shell backgrounding or a detached unmanaged process.
Health is not proven by the JSON schedule record alone.
`bin/fm-supervision-lib.sh` treats `healthy-checkpoint-scheduled` as valid only when the durable schedule record passes integrity checks and the scheduler adapter validates the matching loaded active timer/service registration.
The same Unix account boundary applies: the timer runs under the same user manager and UID as the FirstMate home owner.

## Disposable Timer Proof

Date: 2026-07-16.
Host: WSL2 Linux `LUD-WORKSTATION 6.6.114.1-microsoft-standard-WSL2`.
User and UID: `prode`, `1000`.
Systemctl path: `/usr/bin/systemctl`.
Proof unit prefix: `fm-codex-proof-20260716104001-1364623`.
Proof root: `/tmp/fm-codex-systemd-proof.Q3uOvm`.

Command class run: a uniquely named disposable user service and timer were written under `/home/prode/.config/systemd/user`, started with `systemctl --user enable --now`, observed through `systemctl --user show` and `systemctl --user list-timers`, replaced after a `daemon-reload`, fired again, then disabled, stopped, removed, daemon-reloaded, and reset-failed.

Observed user-manager state:

```text
RuntimePath=/run/user/1000
State=active
Linger=yes
systemctl --user is-system-running: running
```

Observed first registration:

```text
timer LoadState=loaded
timer ActiveState=active
timer UnitFileState=enabled
timer Triggers=fm-codex-proof-20260716104001-1364623.service
service LoadState=loaded
service ActiveState=inactive
service UnitFileState=static
list-timers showed the timer due in about 2 seconds
```

Observed independent firing:

```text
fire count after first due time: 1
```

Observed controlled replacement:

```text
starting the changed timer before daemon-reload produced the expected unit-file-changed warning
daemon-reload plus restart loaded the replacement timer
list-timers showed the replacement due in about 4 seconds
fire count after replacement due time: 2
```

Observed cleanup:

```text
systemctl --user disable --now fm-codex-proof-20260716104001-1364623.timer
systemctl --user stop fm-codex-proof-20260716104001-1364623.service
removed the service and timer files
systemctl --user daemon-reload
systemctl --user reset-failed
service file absent
timer file absent
list-unit-files match empty
list-timers match empty
service LoadState=not-found
timer LoadState=not-found
cleanup_rc=0
```

Final proof result:

```text
PROOF_RESULT=PASS unit=fm-codex-proof-20260716104001-1364623 proof_root=/tmp/fm-codex-systemd-proof.Q3uOvm first_count=1 final_count=2
```

Proof caveat: one diagnostic fire-log line used unescaped `%` characters inside a shell date format, so systemd specifier expansion replaced those fields before the shell ran.
The adapter avoids that proof-script mistake by not placing `%` date formats in the service command.
