#!/usr/bin/env bash
# Class/profile dispatch shim: the single entry point for a capability-profile
# crew spawn. It keeps the routing BRAIN (bin/fm-profile.sh, crew-profiles.json,
# state/crew-profile-bindings.json) local while the launcher (bin/fm-spawn.sh)
# stays stock upstream - the "hybrid" convergence. fm-spawn.sh itself knows only
# native concrete axes (--harness/--model/--effort); this shim resolves a task
# class or profile into those axes, delegates the actual spawn to fm-spawn.sh,
# then records the routing provenance in the task's meta.
# Usage: fm-spawn-profile.sh <task-id> <project-dir> (--class <task-class>|--profile <profile>) [--implementer-provider <provider>|--implementer-task <id>] [--harness <name>] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn-profile.sh <id1>=<repo1> <id2>=<repo2> ... (--class <task-class>|--profile <profile>) [flags]
#   Exactly one of --class / --profile is required; that is what makes this the
#   class/profile entry point. For a plain concrete-axis spawn with no class or
#   profile, call bin/fm-spawn.sh directly.
#   --implementer-provider <provider> and --implementer-task <id> supply the
#   implementer context that counterpart profiles (e.g. reviewer_independent /
#   final_governance_review) need: they are forwarded to fm-profile.sh as
#   --implementer-provider and --for-task respectively, arming both counterpart
#   selection and the provider-independence hard-fail. A counterpart profile
#   spawned without either flag fails loudly from fm-profile.sh; a same-provider
#   resolution hard-fails there too, and this shim spawns nothing in either case.
#   Precedence per axis, highest first: an explicit --harness wins over the
#   profile's harness (and, when it differs, DROPS the profile's model/effort
#   because a binding's model belongs to its own harness, leaving binding_source=
#   empty in meta); explicit --model/--effort win over the profile's per axis.
#   The profile-resolved harness is always passed to fm-spawn.sh as an explicit
#   --harness, which also satisfies fm-spawn.sh's config/crew-dispatch.json
#   explicit-harness backstop (the class/profile choice IS the recorded dispatch
#   consultation).
#   After a successful spawn, appends to each spawned task's state/<id>.meta:
#     class=<task-class>            profile=<capability-profile>
#     provider=<resolved harness's provider>
#     binding_source=env|state|legacy-fallback (empty on an explicit-harness override)
#     candidate_index=0|1|...       (0 is the primary binding)
#     fallback_from=<primary harness> (only when a backup was selected)
#     fallback_reason=<skip reason>  (only when a backup was selected)
#     implementer_provider=<p>      (only when --implementer-provider was given)
#     implementer_task=<id>         (only when --implementer-task was given)
#   Secondmates are exempt: they resolve through config/secondmate-harness, so
#   --secondmate is rejected here.
# Sandboxing mirrors fm-spawn.sh / fm-profile.sh: FM_ROOT_OVERRIDE / FM_HOME /
# FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE are honored so a test or alternate home
# resolves the same paths those scripts do.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

# providers[<harness>] from the committed class->profile table; empty when it
# cannot be read. Used only to re-derive the provider on an explicit-harness
# override, where the resolved binding no longer describes the launched harness.
profiles_provider_of() {
  local h=$1 profiles="$CONFIG/crew-profiles.json"
  [ -f "$profiles" ] || profiles="$FM_ROOT/docs/examples/crew-profiles.json"
  { [ -f "$profiles" ] && command -v jq >/dev/null 2>&1; } || return 0
  jq -r --arg h "$h" '.providers[$h] // empty' "$profiles" 2>/dev/null || true
}

CLASS_ARG=
PROFILE_ARG=
IMPL_PROVIDER_ARG=
IMPL_TASK_ARG=
EXPLICIT_HARNESS=
HARNESS_SET=0
EXPLICIT_MODEL=
MODEL_SET=0
EXPLICIT_EFFORT=
EFFORT_SET=0
PASS=()   # forwarded to fm-spawn.sh verbatim (positionals, --backend, --scout, ...)
POS=()    # positional (non-flag) tokens, used to recover spawned task ids
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      class) CLASS_ARG=$a ;;
      profile) PROFILE_ARG=$a ;;
      implementer-provider) IMPL_PROVIDER_ARG=$a ;;
      implementer-task) IMPL_TASK_ARG=$a ;;
      harness) EXPLICIT_HARNESS=$a; HARNESS_SET=1 ;;
      model) EXPLICIT_MODEL=$a; MODEL_SET=1 ;;
      effort) EXPLICIT_EFFORT=$a; EFFORT_SET=1 ;;
      backend) PASS+=(--backend "$a") ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --class) want_value=class ;;
    --class=*) CLASS_ARG=${a#--class=} ;;
    --profile) want_value=profile ;;
    --profile=*) PROFILE_ARG=${a#--profile=} ;;
    --implementer-provider) want_value=implementer-provider ;;
    --implementer-provider=*) IMPL_PROVIDER_ARG=${a#--implementer-provider=} ;;
    --implementer-task) want_value=implementer-task ;;
    --implementer-task=*) IMPL_TASK_ARG=${a#--implementer-task=} ;;
    --harness) want_value=harness ;;
    --harness=*) EXPLICIT_HARNESS=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) EXPLICIT_MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EXPLICIT_EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) PASS+=("$a") ;;
    --secondmate)
      echo "error: --class/--profile dispatch is crewmate/scout only; secondmates resolve through config/secondmate-harness (use bin/fm-spawn.sh --secondmate)" >&2
      exit 1
      ;;
    -h|--help) usage; exit 0 ;;
    --*) PASS+=("$a") ;;                 # valueless passthrough flags, e.g. --scout
    *) PASS+=("$a"); POS+=("$a") ;;      # positionals (id/project, id=repo pairs)
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

if [ -n "$CLASS_ARG" ] && [ -n "$PROFILE_ARG" ]; then
  echo "error: --class and --profile are mutually exclusive" >&2
  exit 1
fi
if [ -z "$CLASS_ARG$PROFILE_ARG" ]; then
  echo "error: fm-spawn-profile.sh requires --class <task-class> or --profile <profile>; for a plain concrete-axis spawn call bin/fm-spawn.sh directly" >&2
  usage >&2
  exit 1
fi

# Resolve the class/profile to concrete axes. fm-profile.sh emits HARNESS=/MODEL=/
# EFFORT=/CLASS=/PROFILE=/PROVIDER=/BINDING_SOURCE= on stdout and a human audit
# line plus any hard-fail message on stderr; we let stderr flow through and
# propagate a nonzero exit without spawning.
profile_ctx=()
[ -z "$IMPL_PROVIDER_ARG" ] || profile_ctx+=(--implementer-provider "$IMPL_PROVIDER_ARG")
[ -z "$IMPL_TASK_ARG" ] || profile_ctx+=(--for-task "$IMPL_TASK_ARG")
if ! PROFILE_LINES=$("$SCRIPT_DIR/fm-profile.sh" "${CLASS_ARG:-$PROFILE_ARG}" ${profile_ctx[@]+"${profile_ctx[@]}"}); then
  exit 1
fi

P_HARNESS=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^HARNESS=//p')
P_MODEL=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^MODEL=//p')
P_EFFORT=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^EFFORT=//p')
META_CLASS=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^CLASS=//p')
META_PROFILE=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^PROFILE=//p')
META_PROVIDER=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^PROVIDER=//p')
META_BINDING_SOURCE=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^BINDING_SOURCE=//p')
META_CANDIDATE_INDEX=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^CANDIDATE_INDEX=//p')
META_FALLBACK_FROM=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^FALLBACK_FROM=//p')
META_FALLBACK_REASON=$(printf '%s\n' "$PROFILE_LINES" | sed -n 's/^FALLBACK_REASON=//p')

FINAL_HARNESS=$P_HARNESS
FINAL_MODEL=$P_MODEL
FINAL_EFFORT=$P_EFFORT
if [ "$HARNESS_SET" = 1 ] && [ "$EXPLICIT_HARNESS" != "$P_HARNESS" ]; then
  # Explicit harness wins wholesale: the binding's model/effort belong to the
  # binding's own harness, so drop them, take model/effort only from explicit
  # flags, re-derive the provider from the launched harness, and clear
  # binding_source because no binding was applied.
  echo "warning: explicit harness '$EXPLICIT_HARNESS' overrides profile '$META_PROFILE' (resolved harness '$P_HARNESS'); dropping the profile's model/effort" >&2
  FINAL_HARNESS=$EXPLICIT_HARNESS
  if [ "$MODEL_SET" = 1 ]; then FINAL_MODEL=$EXPLICIT_MODEL; else FINAL_MODEL=; fi
  if [ "$EFFORT_SET" = 1 ]; then FINAL_EFFORT=$EXPLICIT_EFFORT; else FINAL_EFFORT=; fi
  META_PROVIDER=$(profiles_provider_of "$EXPLICIT_HARNESS")
  META_BINDING_SOURCE=
  META_CANDIDATE_INDEX=
  META_FALLBACK_FROM=
  META_FALLBACK_REASON=
else
  if [ "$HARNESS_SET" = 1 ]; then FINAL_HARNESS=$EXPLICIT_HARNESS; fi
  if [ "$MODEL_SET" = 1 ]; then FINAL_MODEL=$EXPLICIT_MODEL; fi
  if [ "$EFFORT_SET" = 1 ]; then FINAL_EFFORT=$EXPLICIT_EFFORT; fi
fi

spawn_args=(${PASS[@]+"${PASS[@]}"} --harness "$FINAL_HARNESS")
[ -z "$FINAL_MODEL" ] || spawn_args+=(--model "$FINAL_MODEL")
[ -z "$FINAL_EFFORT" ] || spawn_args+=(--effort "$FINAL_EFFORT")

set +e
"$SCRIPT_DIR/fm-spawn.sh" ${spawn_args[@]+"${spawn_args[@]}"}
spawn_rc=$?
set -e
[ "$spawn_rc" -eq 0 ] || exit "$spawn_rc"

# Recover the spawned task ids from the positionals: a single spawn is
# <id> <project-dir> (id = first positional); a batch is <id>=<repo> pairs
# (mirrors fm-spawn.sh's own batch test: first positional contains '=' and the
# part before '=' has no '/').
ids=()
if [ "${#POS[@]}" -gt 0 ]; then
  first=${POS[0]}
  firstid=${first%%=*}
  if [ "$first" != "$firstid" ] && case "$firstid" in */*) false ;; *) true ;; esac; then
    for p in "${POS[@]}"; do
      case "$p" in
        *=*)
          pid=${p%%=*}
          case "$pid" in */*) : ;; *) ids+=("$pid") ;; esac
          ;;
      esac
    done
  else
    ids+=("$firstid")
  fi
fi

# Append routing provenance to each spawned task's meta. Guard on existence so a
# task fm-spawn.sh did not actually create (a failed batch pair) never gets a
# partial meta.
for id in ${ids[@]+"${ids[@]}"}; do
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || continue
  {
    echo "class=$META_CLASS"
    echo "profile=$META_PROFILE"
    echo "provider=$META_PROVIDER"
    echo "binding_source=$META_BINDING_SOURCE"
    [ -z "$META_CANDIDATE_INDEX" ] || echo "candidate_index=$META_CANDIDATE_INDEX"
    [ -z "$META_FALLBACK_FROM" ] || echo "fallback_from=$META_FALLBACK_FROM"
    [ -z "$META_FALLBACK_REASON" ] || echo "fallback_reason=$META_FALLBACK_REASON"
    [ -z "$IMPL_PROVIDER_ARG" ] || echo "implementer_provider=$IMPL_PROVIDER_ARG"
    [ -z "$IMPL_TASK_ARG" ] || echo "implementer_task=$IMPL_TASK_ARG"
  } >> "$meta"
done

exit 0
