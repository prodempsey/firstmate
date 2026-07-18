#!/usr/bin/env bash
# Resolve a task class or capability profile to a concrete (harness, model,
# effort) binding for a crew spawn - the two-level indirection that keeps
# model/provider choices out of committed prompts, briefs, and scripts:
#   task class -> capability profile     (defaults: docs/examples/crew-profiles.json)
#   profile    -> harness/model/effort   (runtime state: state/crew-profile-bindings.json)
# Usage: fm-profile.sh <task-class|profile-name> [--implementer-provider <p>] [--for-task <id>]
#   The positional arg is tried as a task class first (a key of task_classes in
#   crew-profiles.json); otherwise it must be a known profile name (a
#   task_classes value or default_profile). Anything else is a loud error.
#   --implementer-provider <p>  the provider that produced the work under review;
#                               selects counterpart bindings and arms the
#                               provider-independence check.
#   --for-task <id>             read the implementer provider from provider= in
#                               state/<id>.meta. A meta with no provider= (written
#                               before provider recording existed) warns and
#                               continues fail-open; a missing meta file errors.
# Binding precedence, highest first:
#   1. env overrides  (uppercase the profile/class name, non-alnum -> "_"):
#        FM_CREW_PROFILE            force one profile for every resolution
#        FM_PROFILE__<TASK_CLASS>   remap one task class to another profile
#        FM_HARNESS__<PROFILE>      rebind the harness field of one profile
#        FM_MODEL__<PROFILE>        rebind the model field of one profile
#        FM_EFFORT__<PROFILE>       rebind the effort field of one profile
#      An FM_HARNESS__ override on a counterpart profile replaces the counterpart
#      binding wholesale (model/effort then come only from FM_MODEL__/FM_EFFORT__),
#      because a counterpart's model belongs to the counterpart's harness.
#   2. state/crew-profile-bindings.json (hand-editable runtime state, NEVER
#      committed; see docs/examples/crew-profile-bindings.json for the shape).
#      A direct binding may include an ordered backups[] array of direct
#      bindings. The resolver selects the first candidate whose harness command
#      exists and whose harness/provider circuits are enabled in optional
#      state/provider-failover.json.
#      A binding whose value is a counterpart map keyed by provider selects the
#      entry whose KEY equals the implementer provider (counterpart.anthropic is
#      the binding used WHEN the implementer was anthropic); no known implementer
#      provider is a loud error. Each direct counterpart entry may carry its own
#      backups[] array; every selected candidate still must be provider-independent.
#   3. legacy fallback: harness from bin/fm-harness.sh crew, empty model/effort -
#      byte-identical to the pre-profile behavior. A missing bindings file or an
#      empty binding object always lands here, so nothing changes until the
#      captain seeds a binding.
# A binding's provider is providers[harness] from the committed config. When the
# resolved class carries constraints.<class>.provider_independent_of_implementer
# and the implementer provider is known, resolving to that same provider is a
# hard error (exit nonzero).
# Output (stdout, one per line): HARNESS= MODEL= EFFORT= PROFILE= CLASS=
# PROVIDER= BINDING_SOURCE=env|state|legacy-fallback plus CANDIDATE_INDEX=,
# FALLBACK_FROM=, and FALLBACK_REASON=. CLASS is empty when invoked with a bare
# profile name. Candidate index 0 is the primary. One human audit line goes to
# stderr.
# Sandboxing: respects FM_ROOT_OVERRIDE / FM_HOME / FM_CONFIG_OVERRIDE /
# FM_STATE_OVERRIDE exactly like bin/fm-harness.sh. crew-profiles.json is read
# from $CONFIG first, falling back to the repo's shipped defaults under
# docs/examples/ (config/ is per-fleet local state and is never tracked), so a home
# whose config dir lacks it still resolves.
# JSON is read with jq, the repo's established JSON dependency (fm-x-reply.sh,
# fm-turnend-guard.sh, fm-bootstrap.sh's crew-dispatch validation; bootstrap
# offers its install).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-provider-failover.sh
. "$SCRIPT_DIR/fm-provider-failover.sh"

die() { echo "fm-profile: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq not found (the repo's JSON dependency; bootstrap installs it)"

ARG=
IMPL_PROVIDER=
IMPL_LEGACY_META=0
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) die "--$want_value requires a value" ;;
    esac
    case "$want_value" in
      implementer-provider) IMPL_PROVIDER=$a ;;
      for-task)
        meta="$STATE/$a.meta"
        [ -f "$meta" ] || die "--for-task $a: no meta at $meta"
        IMPL_PROVIDER=$(grep '^provider=' "$meta" | head -1 | cut -d= -f2- || true)
        if [ -z "$IMPL_PROVIDER" ]; then
          echo "fm-profile: warning: $meta has no provider= (legacy meta); independence check is fail-open for this task" >&2
          IMPL_LEGACY_META=1
        fi
        ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --implementer-provider) want_value=implementer-provider ;;
    --for-task) want_value=for-task ;;
    --*) die "unknown flag $a" ;;
    *)
      [ -z "$ARG" ] || die "expected exactly one task class or profile name, got '$ARG' and '$a'"
      ARG=$a
      ;;
  esac
done
[ -z "$want_value" ] || die "--$want_value requires a value"
[ -n "$ARG" ] || die "usage: fm-profile.sh <task-class|profile-name> [--implementer-provider <p>] [--for-task <id>]"

PROFILES="$CONFIG/crew-profiles.json"
[ -f "$PROFILES" ] || PROFILES="$FM_ROOT/docs/examples/crew-profiles.json"
[ -f "$PROFILES" ] || die "no crew-profiles.json under $CONFIG or $FM_ROOT/docs/examples"
jq -e . "$PROFILES" >/dev/null 2>&1 || die "invalid JSON in $PROFILES"

BINDINGS="$STATE/crew-profile-bindings.json"

# Uppercase a class/profile name into its env-override key segment
# (non-alphanumerics become "_").
env_key() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | LC_ALL=C sed 's/[^A-Z0-9]/_/g'
}

# Indirect env read; empty when unset.
env_val() {
  eval "printf '%s' \"\${$1:-}\""
}

# --- class/profile resolution -------------------------------------------------

CLASS=
PROFILE=
if jq -e --arg a "$ARG" '.task_classes | has($a)' "$PROFILES" >/dev/null; then
  CLASS=$ARG
  PROFILE=$(jq -r --arg a "$ARG" '.task_classes[$a]' "$PROFILES")
elif jq -e --arg a "$ARG" '([.default_profile // empty] + (.task_classes | to_entries | map(.value))) | index($a)' "$PROFILES" >/dev/null; then
  PROFILE=$ARG
else
  die "unknown task class or profile '$ARG' (not in task_classes or profile names of $PROFILES)"
fi

if [ -n "$CLASS" ]; then
  remap=$(env_val "FM_PROFILE__$(env_key "$CLASS")")
  [ -z "$remap" ] || PROFILE=$remap
fi
[ -z "${FM_CREW_PROFILE:-}" ] || PROFILE=$FM_CREW_PROFILE

# --- binding resolution --------------------------------------------------------

PKEY=$(env_key "$PROFILE")
ENV_HARNESS=$(env_val "FM_HARNESS__$PKEY")
ENV_MODEL=$(env_val "FM_MODEL__$PKEY")
ENV_EFFORT=$(env_val "FM_EFFORT__$PKEY")

HARNESS=
MODEL=
EFFORT=
BINDING_SOURCE=legacy-fallback
BINDING=

if [ -f "$BINDINGS" ]; then
  # Fail-closed bindings validation (ORD-225 Phase 2E): a present-but-invalid
  # bindings file stops resolution entirely - no legacy fallback, no default
  # model, no dispatch. A MISSING file keeps the documented legacy fallback
  # above (which resolves to the crew harness with an empty model and can never
  # select Fable), unchanged from pre-slice behavior. The validator prints one
  # stable BINDINGS_* code to stderr and preserves the invalid file untouched.
  "$SCRIPT_DIR/fm-bindings-validate.sh" "$BINDINGS" --quiet --write-sidecar ||
    die "bindings validation failed for $BINDINGS (code above; file preserved for investigation; refusing to resolve or dispatch)"
  BINDING=$(jq -c --arg p "$PROFILE" '.[$p] // empty | objects' "$BINDINGS" || true)
  if [ -n "$BINDING" ]; then
    if [ "$(printf '%s' "$BINDING" | jq 'has("counterpart")')" = "true" ]; then
      if [ -n "$ENV_HARNESS" ]; then
        # Env harness override replaces a counterpart binding wholesale (header).
        BINDING='{}'
      else
        [ -n "$IMPL_PROVIDER" ] || die "profile '$PROFILE' uses a counterpart binding; the implementer provider is unknown (pass --implementer-provider or --for-task <id> whose meta records provider=)"
        BINDING=$(printf '%s' "$BINDING" | jq -c --arg ip "$IMPL_PROVIDER" '.counterpart[$ip] // empty | objects' || true)
        [ -n "$BINDING" ] || die "profile '$PROFILE' has no counterpart entry for implementer provider '$IMPL_PROVIDER'"
      fi
    fi
    if ! printf '%s\n' "$BINDING" | jq -e \
      '(.backups? // []) | type == "array" and all(.[]; type == "object")' >/dev/null; then
      die "profile '$PROFILE' has invalid backups (expected an array of direct binding objects)"
    fi
    HARNESS=$(printf '%s' "$BINDING" | jq -r '.harness // empty')
    MODEL=$(printf '%s' "$BINDING" | jq -r '.model // empty')
    EFFORT=$(printf '%s' "$BINDING" | jq -r '.effort // empty')
    if [ -n "$HARNESS$MODEL$EFFORT" ]; then
      BINDING_SOURCE=state
    fi
  fi
fi

if [ -n "$ENV_HARNESS$ENV_MODEL$ENV_EFFORT" ]; then
  [ -z "$ENV_HARNESS" ] || HARNESS=$ENV_HARNESS
  [ -z "$ENV_MODEL" ] || MODEL=$ENV_MODEL
  [ -z "$ENV_EFFORT" ] || EFFORT=$ENV_EFFORT
  BINDING_SOURCE='env'
fi

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" crew)
  [ -n "$HARNESS" ] || die "could not resolve a fallback crew harness"
fi

# --- candidate availability + provider independence --------------------------

PRIMARY_HARNESS=$HARNESS
CANDIDATE_INDEX=0
FALLBACK_FROM=
FALLBACK_REASON=
PROVIDER=
INDEPENDENCE_REQUIRED=0
if [ -n "$CLASS" ] && jq -e --arg c "$CLASS" \
  '.constraints[$c].provider_independent_of_implementer == true' "$PROFILES" >/dev/null 2>&1; then
  INDEPENDENCE_REQUIRED=1
  if [ -z "$IMPL_PROVIDER" ] && [ "$IMPL_LEGACY_META" = 0 ]; then
    echo "fm-profile: warning: class '$CLASS' requires provider independence but no implementer provider was supplied; check skipped" >&2
  fi
fi

# Preserve the resolved primary as candidate zero, then append state-configured
# backups. Env overrides affect only candidate zero, just as they affected the
# single binding before failover existed.
BINDING_JSON=$BINDING
[ -n "$BINDING_JSON" ] || BINDING_JSON='{}'
CANDIDATES=$(jq -cn --arg h "$HARNESS" --arg m "$MODEL" --arg e "$EFFORT" \
  --argjson binding "$BINDING_JSON" \
  '[{harness:$h, model:$m, effort:$e}] + ($binding.backups // [])')
SKIP_REASONS=()
CANDIDATE_COUNT=$(printf '%s\n' "$CANDIDATES" | jq 'length')
SELECTED=0
index=0
while [ "$index" -lt "$CANDIDATE_COUNT" ]; do
  candidate=$(printf '%s\n' "$CANDIDATES" | jq -c ".[$index]")
  candidate_harness=$(printf '%s\n' "$candidate" | jq -r '.harness // empty')
  candidate_model=$(printf '%s\n' "$candidate" | jq -r '.model // empty')
  candidate_effort=$(printf '%s\n' "$candidate" | jq -r '.effort // empty')
  case "$candidate_effort" in
    ''|low|medium|high|xhigh|max) ;;
    *) die "resolved effort '$candidate_effort' for profile '$PROFILE' candidate $index is not one of low, medium, high, xhigh, max" ;;
  esac
  candidate_provider=$(jq -r --arg h "$candidate_harness" '.providers[$h] // empty' "$PROFILES")

  unavailable=
  if [ "$INDEPENDENCE_REQUIRED" -eq 1 ] && [ -n "$IMPL_PROVIDER" ] && \
     [ -n "$candidate_provider" ] && [ "$candidate_provider" = "$IMPL_PROVIDER" ]; then
    unavailable="class '$CLASS' requires a provider independent of the implementer; candidate harness '$candidate_harness' uses '$candidate_provider'"
  else
    unavailable=$(fm_failover_candidate_reason "$candidate_harness" "$candidate_provider")
    availability_rc=$?
    [ "$availability_rc" -ne 2 ] || die "could not evaluate provider failover state"
    if [ "$availability_rc" -eq 1 ]; then
      unavailable=
    fi
  fi

  if [ -z "$unavailable" ]; then
    HARNESS=$candidate_harness
    MODEL=$candidate_model
    EFFORT=$candidate_effort
    PROVIDER=$candidate_provider
    CANDIDATE_INDEX=$index
    SELECTED=1
    break
  fi
  SKIP_REASONS+=("$candidate_harness: $unavailable")
  index=$((index + 1))
done

if [ "$SELECTED" -eq 0 ]; then
  joined=$(IFS='; '; echo "${SKIP_REASONS[*]}")
  die "no available candidate for profile '$PROFILE' ($joined)"
fi
if [ "$CANDIDATE_INDEX" -gt 0 ]; then
  FALLBACK_FROM=$PRIMARY_HARNESS
  FALLBACK_REASON=$(IFS='; '; echo "${SKIP_REASONS[*]}")
fi
if [ "$INDEPENDENCE_REQUIRED" -eq 1 ] && [ -n "$IMPL_PROVIDER" ] && [ -z "$PROVIDER" ]; then
  echo "fm-profile: warning: harness '$HARNESS' has no providers[] entry in $PROFILES; cannot verify provider independence for class '$CLASS'" >&2
fi

# --- output ---------------------------------------------------------------------

echo "fm-profile: ${CLASS:--} -> $PROFILE -> $HARNESS/${MODEL:-(default)} effort=${EFFORT:--} source=$BINDING_SOURCE candidate=$CANDIDATE_INDEX${FALLBACK_FROM:+ fallback_from=$FALLBACK_FROM reason=$FALLBACK_REASON}" >&2
printf 'HARNESS=%s\n' "$HARNESS"
printf 'MODEL=%s\n' "$MODEL"
printf 'EFFORT=%s\n' "$EFFORT"
printf 'PROFILE=%s\n' "$PROFILE"
printf 'CLASS=%s\n' "$CLASS"
printf 'PROVIDER=%s\n' "$PROVIDER"
printf 'BINDING_SOURCE=%s\n' "$BINDING_SOURCE"
printf 'CANDIDATE_INDEX=%s\n' "$CANDIDATE_INDEX"
printf 'FALLBACK_FROM=%s\n' "$FALLBACK_FROM"
printf 'FALLBACK_REASON=%s\n' "$FALLBACK_REASON"
