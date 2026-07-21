#!/bin/sh
# Self-identifying launch wrapper (spec section 5.2 / 514-562). The adapter starts THIS
# script directly as a marker-bearing tmux window's initial command - never an
# interactive shell, so no markerless endpoint is ever created. Its env carries
# CP_LAUNCH_MARKER / CP_TASK_ID / CP_RUN_GENERATION, so the marker is observable from the
# first instant, before this registration write.
#
# REGISTER FIRST, THEN EXEC (PID PRESERVED). The wrapper's FIRST action writes the
# HMAC-signed registration record, then it `exec`s the harness so the process image is
# replaced and THIS shell's PID becomes the harness PID - execve semantics, no lingering
# wrapper and no distinct child process. The registration records the identity the PID
# will have AFTER exec: start ticks, parent, and PTY are preserved by exec and read live
# from this shell; the executable realpath and argv hash change at exec and are computed
# for the harness we are about to become. record-spawn then reads back exactly that
# identity from /proc once exec completes.
#
# A one-shot Node helper (cp-reg-write.mjs) does the /proc read, HMAC, and file write,
# because the canonical HMAC input is NUL-joined and a POSIX shell cannot hold NUL bytes
# in a variable. That helper is a transient child that exits before the exec below; it is
# never part of the running agent's process tree.
#
#   cp-launch.sh <harness_cmd> [harness_args...]
# env: CP_LAUNCH_MARKER, CP_TASK_ID, CP_RUN_GENERATION, CP_BIND_NONCE, CP_REG_FILE
#      optional CP_WORKTREE, CP_HARNESS
set -eu

: "${CP_REG_FILE:?cp-launch: CP_REG_FILE is required}"

if [ "$#" -eq 0 ]; then
  echo "cp-launch: a harness command is required" >&2
  exit 64
fi

# Resolve this script's directory to find the co-located registration helper, whatever
# the caller's working directory. CDPATH is cleared so `cd` cannot resolve elsewhere.
CDPATH=''
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)

# FIRST action: write the registration record for THIS shell's PID ($$), recording the
# identity it will have after the exec below. `exec` preserves $$.
node "$script_dir/cp-reg-write.mjs" "$$" "$CP_REG_FILE" "$@"

# THEN replace this shell's process image with the harness so the registered PID is
# preserved as the agent PID (spec section 5.2 "execs the harness so the PID is preserved").
exec "$@"
