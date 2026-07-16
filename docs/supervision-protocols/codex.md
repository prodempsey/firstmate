Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. If the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
6. A normal checkpoint completion writes `state/.codex-watch-checkpoint.next.json` before returning, and that durable record is what proves continuity while no foreground watcher process is running.
7. A failed checkpoint writes `state/.codex-watch-checkpoint.last.json` with `previous_result=failed` and does not leave a healthy next-checkpoint schedule.
8. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
9. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
The schedule record carries the checkpoint owner, primary identity, home, prior start and end, result, next due time, cadence, maximum lateness, generation, lease id, mechanism, version, and integrity hash.
`FM_CODEX_WATCH_CHECKPOINT_MAX_LATENESS` controls the lateness window and defaults to 60 seconds.
