#!/usr/bin/env bash
# fm-governance-lib.sh - shared governance primitives for the Memory PR-1 incident
# prevention controls. This library is the ONE owner of the mechanical rules that
# stop the specific failure classes the incident exposed; the thin CLIs
# (fm-govern.sh, fm-hold.sh, fm-freeze-check.sh) and the fm-spawn.sh dispatch gate
# all call into it rather than re-rolling the logic.
#
# It is a sourced library (like bin/fm-classify-lib.sh), so it sets no shell
# options and defines only functions and constants. Every function is a pure read
# of its arguments or of an explicit file path; nothing here mutates fleet state
# except the record/hold writers, which write only the caller-named path.
#
# Governance model, in one paragraph. A governed change carries a single canonical
# DELIVERY MODE (local-only|fork-pr|upstream-pr), a single canonical repository,
# base, branch, and approved scope, and a machine-readable RECORD
# (state/<id>.governance.json) that tracks the exact SHA at each gate: frozen
# candidate, independent review, QA, and Captain authorization. The load-bearing
# invariant is exact-SHA equality: an attestation is valid ONLY for the precise
# commit it was made against, so any branch-head movement - a descendant, a matching
# tree at a new commit, a squash, a cherry-pick - automatically invalidates every
# downstream attestation because the head SHA no longer equals the attested SHA.

# --- resolution -------------------------------------------------------------

_FM_GOV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_GOV_LIB_DIR="."
# FM_HOME selects the operational home; state/ and config/ come from it. These are
# resolved lazily via fm_gov_state/fm_gov_config so a test can override FM_HOME
# after sourcing.
fm_gov_home() { printf '%s' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$_FM_GOV_LIB_DIR/.." && pwd)}}"; }
fm_gov_state() { printf '%s' "${FM_STATE_OVERRIDE:-$(fm_gov_home)/state}"; }
fm_gov_config() { printf '%s' "${FM_CONFIG_OVERRIDE:-$(fm_gov_home)/config}"; }

# --- constants --------------------------------------------------------------

FM_GOV_SCHEMA_VERSION='fm-gov/v1'
FM_GOV_CLASSIFY_RULE_VERSION='gov-rules/v1'
# The canonical delivery modes. local-only never touches a remote; fork-pr lands a
# PR on a contributor fork; upstream-pr lands a PR on the canonical upstream repo.
FM_GOV_DELIVERY_MODES='local-only fork-pr upstream-pr'

# The default protected-path list. A task whose declared scope or intended paths
# touch any of these enters governed mode automatically (Scope B). It is a set of
# extended-regex anchors matched against each path. A home may EXTEND (never shrink)
# it via config/governed-paths.txt, one regex per line, '#' comments ignored.
# Kept deliberately broad-but-specific: the failure mode of a miss is an ungoverned
# sensitive change, so the list errs toward inclusion.
FM_GOV_PROTECTED_PATHS_DEFAULT='
^memory/
^bin/fm-spawn\.sh$
^bin/fm-teardown\.sh$
^bin/fm-watch
^bin/fm-dispatch
^bin/fm-merge-local\.sh$
^bin/fm-pr-merge\.sh$
^bin/fm-promote\.sh$
^bin/fm-governance-lib\.sh$
^bin/fm-govern\.sh$
^bin/fm-hold\.sh$
^bin/fm-freeze-check\.sh$
^bin/fm-lease
^bin/fm-lock
^\.github/workflows/
^AGENTS\.md$
^CLAUDE\.md$
^config/canonical-trunk\.json$
'

# Governed-intent keywords. A task whose declared scope text names any of these
# concerns is governed even when no concrete path is known yet (intake-time
# provisional classification). Extended regex, matched case-insensitively.
FM_GOV_INTENT_RE='canonical (memory|registry)|memory registry|memory lifecycle|activation|supersession|recovery|snapshot|doctor integrity|auth(enticat|oriz)|permission|secret|credential|security|deploy|runtime fold|branch protection|no-mistakes|merge control|history rewrite|force[- ]?push|rebase shared|dispatch|spawn|watcher|teardown|worktree|fleet lifecycle|schema migration|production data|data migration|destructive|irreversible'

# --- classification (Scope B) ----------------------------------------------

# Print the effective protected-path regex set (default + optional home override),
# one regex per line, comments/blank lines stripped.
fm_gov_protected_paths() {
  local override line
  override="$(fm_gov_config)/governed-paths.txt"
  printf '%s\n' "$FM_GOV_PROTECTED_PATHS_DEFAULT" | sed '/^[[:space:]]*$/d'
  if [ -f "$override" ]; then
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      printf '%s\n' "$line"
    done < "$override"
  fi
}

# 0 if <path> matches any protected-path regex. Pure.
fm_gov_path_is_protected() {  # <path>
  local path=$1 re
  [ -n "$path" ] || return 1
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    printf '%s' "$path" | grep -qE "$re" && return 0
  done <<EOF
$(fm_gov_protected_paths)
EOF
  return 1
}

# Classify a task from its scope text and/or an explicit path list. Prints
# "<governed 0|1>\t<matched-rule-ids csv>". A governed verdict fires when any given
# path is protected OR the scope text names a governed-intent keyword.
# Args: --scope <text> --paths <newline-list-file|-> (either or both).
fm_gov_classify() {  # <scope-text> [path ...]
  local scope=$1; shift || true
  local matched='' governed=0 p
  if [ -n "$scope" ] && printf '%s' "$scope" | grep -qiE "$FM_GOV_INTENT_RE"; then
    governed=1
    matched="intent-keyword"
  fi
  for p in "$@"; do
    [ -n "$p" ] || continue
    if fm_gov_path_is_protected "$p"; then
      governed=1
      matched="${matched:+$matched,}protected-path:$p"
    fi
  done
  printf '%s\t%s' "$governed" "${matched:-none}"
}

# --- delivery-mode validation (Scope A) ------------------------------------

# Count the unique non-empty whitespace-separated tokens in a string.
_fm_gov_count_unique() {  # <space-separated-list>
  printf '%s\n' "$1" | tr '[:blank:]' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' '
}

fm_gov_delivery_mode_valid() {  # <mode>
  case " $FM_GOV_DELIVERY_MODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# 0 if the given instruction/brief text requests a REMOTE delivery action - a push,
# a PR creation/update, or an upstream landing. This is the predicate that catches a
# local-only task whose brief nonetheless says "push/update PR #592".
fm_gov_text_requests_remote() {  # <text>
  local t=$1
  printf '%s' "$t" | grep -qiE 'git[ _-]?push|\bpush(es|ed|ing)?\b (to|the|this|your|its|a )?(remote|branch|fork|origin|upstream|pr)|open(ing|s)? (a |the )?pr\b|creat(e|es|ing) (a |the )?pull request|creat(e|es|ing) (a |the )?pr\b|updat(e|es|ing) (the |a )?pr\b|pr #?[0-9]+|pull request #?[0-9]+|gh-axi pr|gh pr (create|merge|edit)|upstream (land|merge|contribution|pr)'
}

# Validate a declared delivery mode against a structured task declaration. All
# inputs are explicit so the check is deterministic and testable. Returns 0 when
# consistent; on contradiction prints one "CONFLICT:" line per problem to stderr,
# each naming BOTH conflicting sides and where they came from, and returns 1.
#
# Args (flag form): --mode M --target upstream|fork|none --repo R --pr N
#                   --canonical-repos "r1 r2" --canonical-branches "b1 b2"
#                   --canonical-prs "n1 n2" --deploy-target T --deploy-reachable 0|1
#                   --merge-method M --preserves-sha 0|1 --text-file F
fm_gov_delivery_validate() {
  local mode='' target='none' repo='' pr='' text_file='' merge_method='' preserves_sha='1'
  local deploy_target='' deploy_reachable='1'
  local canon_repos='' canon_branches='' canon_prs=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode=$2; shift 2 ;;
      --target) target=$2; shift 2 ;;
      --repo) repo=$2; shift 2 ;;
      --pr) pr=$2; shift 2 ;;
      --canonical-repos) canon_repos=$2; shift 2 ;;
      --canonical-branches) canon_branches=$2; shift 2 ;;
      --canonical-prs) canon_prs=$2; shift 2 ;;
      --deploy-target) deploy_target=$2; shift 2 ;;
      --deploy-reachable) deploy_reachable=$2; shift 2 ;;
      --merge-method) merge_method=$2; shift 2 ;;
      --preserves-sha) preserves_sha=$2; shift 2 ;;
      --text-file) text_file=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  local conflicts=0 text=''
  [ -n "$text_file" ] && [ -f "$text_file" ] && text=$(cat "$text_file")

  if ! fm_gov_delivery_mode_valid "$mode"; then
    echo "CONFLICT: delivery mode '$mode' is not one of: $FM_GOV_DELIVERY_MODES (a governed task must declare an explicit mode before dispatch)" >&2
    return 1
  fi

  # local-only must never carry a remote instruction, PR reference, or push target.
  if [ "$mode" = local-only ]; then
    if [ -n "$text" ] && fm_gov_text_requests_remote "$text"; then
      echo "CONFLICT: mode=local-only [declared delivery mode] vs a push/PR instruction found in the brief/task text [${text_file:-inline}]. A local-only change has no remote and opens no PR; these cannot both be canonical." >&2
      conflicts=$((conflicts + 1))
    fi
    if [ -n "$pr" ]; then
      echo "CONFLICT: mode=local-only [declared delivery mode] vs --pr $pr [target PR]. local-only landings have no PR." >&2
      conflicts=$((conflicts + 1))
    fi
    if [ "$target" = upstream ] || [ "$target" = fork ]; then
      echo "CONFLICT: mode=local-only [declared delivery mode] vs --target $target [remote target]. local-only has no remote target." >&2
      conflicts=$((conflicts + 1))
    fi
  fi

  # fork-pr must target the fork, upstream-pr must target the canonical upstream.
  if [ "$mode" = fork-pr ] && [ "$target" = upstream ]; then
    echo "CONFLICT: mode=fork-pr [declared delivery mode] vs --target upstream [PR/repository target]. A fork-pr change lands on the contributor fork, not upstream." >&2
    conflicts=$((conflicts + 1))
  fi
  if [ "$mode" = upstream-pr ] && [ "$target" = fork ]; then
    echo "CONFLICT: mode=upstream-pr [declared delivery mode] vs --target fork [PR/repository target]. An upstream-pr change lands upstream, not on a fork." >&2
    conflicts=$((conflicts + 1))
  fi

  # More than one canonical repository, branch, or PR is a split-brain declaration.
  local n
  n=$(_fm_gov_count_unique "$canon_repos")
  if [ "$n" -gt 1 ]; then
    echo "CONFLICT: $n repositories are declared canonical [$canon_repos]. Exactly one repository may be canonical for a governed change." >&2
    conflicts=$((conflicts + 1))
  fi
  n=$(_fm_gov_count_unique "$canon_branches")
  if [ "$n" -gt 1 ]; then
    echo "CONFLICT: $n branches are declared canonical [$canon_branches]. Exactly one branch may be canonical." >&2
    conflicts=$((conflicts + 1))
  fi
  n=$(_fm_gov_count_unique "$canon_prs")
  if [ "$n" -gt 1 ]; then
    echo "CONFLICT: $n PRs are declared canonical [$canon_prs]. Exactly one delivery route may be canonical." >&2
    conflicts=$((conflicts + 1))
  fi

  # The requested delivery path must reach the configured operational deployment target.
  if [ -n "$deploy_target" ] && [ "$deploy_reachable" != 1 ]; then
    echo "CONFLICT: the requested delivery path does not reach the configured operational deployment target [$deploy_target]." >&2
    conflicts=$((conflicts + 1))
  fi

  # The requested merge method must preserve the exact reviewed SHA.
  if [ -n "$merge_method" ] && [ "$preserves_sha" != 1 ]; then
    echo "CONFLICT: merge method '$merge_method' cannot preserve the exact reviewed SHA required for a governed landing." >&2
    conflicts=$((conflicts + 1))
  fi

  [ "$conflicts" -eq 0 ]
}

# --- record I/O + exact-SHA invalidation (Scope C) -------------------------

# Path to a task's governance record.
fm_gov_record_path() { printf '%s/%s.governance.json' "$(fm_gov_state)" "$1"; }

# Require jq; governance records are JSON and jq is a bootstrap tool.
fm_gov_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "error: jq not found; governance records cannot be read or written" >&2
  return 2
}

# Emit an ISO-8601 UTC timestamp, or the caller-provided FM_GOV_NOW override
# (so tests are deterministic).
fm_gov_now() { printf '%s' "${FM_GOV_NOW:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"; }

# Append one line to the governance audit trail.
fm_gov_audit() {  # <task> <event> <detail>
  local log
  log="$(fm_gov_state)/governance-audit.log"
  mkdir -p "$(fm_gov_state)" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$(fm_gov_now)" "$1" "$2" "$3" >> "$log" 2>/dev/null || true
}

# Create or overwrite a task's governance record from explicit fields. Idempotent
# init; preserves nothing (callers use fm_gov_record_set for field updates).
fm_gov_record_init() {  # <task> <deliveryMode> <repoPath> <repoIdentity> <branch> <baseSha> <headSha> <approvedScopeCsv> <governed 0|1>
  fm_gov_require_jq || return 2
  local task=$1 mode=$2 repo=$3 ident=$4 branch=$5 base=$6 head=$7 scope=$8 governed=$9
  local path scope_json
  path=$(fm_gov_record_path "$task")
  mkdir -p "$(fm_gov_state)" 2>/dev/null || true
  scope_json=$(printf '%s' "$scope" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc .)
  jq -n \
    --arg sv "$FM_GOV_SCHEMA_VERSION" --arg task "$task" --arg mode "$mode" \
    --arg repo "$repo" --arg ident "$ident" --arg branch "$branch" \
    --arg base "$base" --arg head "$head" --argjson scope "$scope_json" \
    --argjson governed "$([ "$governed" = 1 ] && echo true || echo false)" \
    --arg now "$(fm_gov_now)" '
    {schemaVersion:$sv, taskId:$task, deliveryMode:(if $mode=="" then null else $mode end),
     repository:{path:$repo, identity:$ident}, branch:$branch, baseSha:$base, headSha:$head,
     approvedScope:$scope, governed:$governed,
     classification:{ruleVersion:"'"$FM_GOV_CLASSIFY_RULE_VERSION"'", provisional:true, matched:[]},
     frozen:{sha:null, at:null}, review:{sha:null, verdict:null, at:null},
     qa:{sha:null, verdict:null, at:null}, captainAuth:{sha:null, ref:null, at:null},
     hold:{held:false, ref:null}, invalidation:{reason:null, at:null},
     landingReady:false, evidence:[],
     history:[{ts:$now, event:"init", detail:("governed="+($governed|tostring))}]}
  ' > "$path"
  fm_gov_audit "$task" init "mode=$mode base=$base head=$head governed=$governed"
}

# Read a single dotted field from a record (jq path without leading dot).
fm_gov_record_get() {  # <task> <jq-path>
  fm_gov_require_jq || return 2
  local path; path=$(fm_gov_record_path "$1")
  [ -f "$path" ] || { echo "error: no governance record for $1" >&2; return 1; }
  # Note: do NOT use jq's `//` here - it treats boolean false as absent and would
  # render a real `false` (e.g. landingReady) as empty. Map only null to empty.
  jq -r ".$2 | if . == null then \"\" else . end" "$path"
}

# Freeze the candidate at an exact SHA (Scope C/D). Refuses if the record's headSha
# does not match the SHA being frozen (freeze must name the exact current head).
fm_gov_record_freeze() {  # <task> <sha>
  fm_gov_require_jq || return 2
  local task=$1 sha=$2 path; path=$(fm_gov_record_path "$task")
  [ -f "$path" ] || { echo "error: no governance record for $task" >&2; return 1; }
  local now; now=$(fm_gov_now)
  jq --arg sha "$sha" --arg now "$now" '
    .frozen={sha:$sha, at:$now} | .headSha=$sha | .invalidation={reason:null, at:null}
    | .history += [{ts:$now, event:"freeze", detail:$sha}]' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
  fm_gov_audit "$task" freeze "$sha"
}

# Record an attestation (review|qa|captain-auth) at an exact SHA. The attestation is
# refused unless it names the currently-frozen SHA - an attestation can only be made
# against the frozen candidate, never a moving head.
fm_gov_record_attest() {  # <task> <gate review|qa|captain-auth> <sha> <verdict|ref>
  fm_gov_require_jq || return 2
  local task=$1 gate=$2 sha=$3 val=$4 path; path=$(fm_gov_record_path "$task")
  [ -f "$path" ] || { echo "error: no governance record for $task" >&2; return 1; }
  local frozen; frozen=$(jq -r '.frozen.sha // ""' "$path")
  if [ -z "$frozen" ]; then
    echo "error: cannot attest $gate for $task - no frozen candidate; freeze first" >&2
    return 1
  fi
  if [ "$sha" != "$frozen" ]; then
    echo "error: cannot attest $gate at $sha for $task - the frozen candidate is $frozen (attestation must name the frozen SHA)" >&2
    return 1
  fi
  local now; now=$(fm_gov_now)
  case "$gate" in
    review) jq --arg s "$sha" --arg v "$val" --arg n "$now" '.review={sha:$s,verdict:$v,at:$n} | .history+=[{ts:$n,event:"review",detail:($s+" "+$v)}]' "$path" > "$path.tmp" ;;
    qa) jq --arg s "$sha" --arg v "$val" --arg n "$now" '.qa={sha:$s,verdict:$v,at:$n} | .history+=[{ts:$n,event:"qa",detail:($s+" "+$v)}]' "$path" > "$path.tmp" ;;
    captain-auth) jq --arg s "$sha" --arg r "$val" --arg n "$now" '.captainAuth={sha:$s,ref:$r,at:$n} | .history+=[{ts:$n,event:"captain-auth",detail:($s+" "+$r)}]' "$path" > "$path.tmp" ;;
    *) echo "error: unknown gate '$gate'" >&2; return 1 ;;
  esac
  mv "$path.tmp" "$path"
  fm_gov_audit "$task" "attest:$gate" "$sha $val"
  fm_gov_record_recompute_landing "$task"
}

# THE INVARIANT (Scope C). Observe a new head SHA and invalidate every downstream
# attestation when the head no longer equals the frozen candidate, or when any
# canonical field changed. Idempotent: a head equal to the frozen SHA is a no-op.
fm_gov_record_observe() {  # <task> [--head SHA] [--base SHA] [--repo-identity ID] [--branch B] [--mode M] [--scope CSV]
  fm_gov_require_jq || return 2
  local task=$1; shift
  local path; path=$(fm_gov_record_path "$task")
  [ -f "$path" ] || { echo "error: no governance record for $task" >&2; return 1; }
  local nhead='' nbase='' nident='' nbranch='' nmode='' nscope='' have_scope=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) nhead=$2; shift 2 ;;
      --base) nbase=$2; shift 2 ;;
      --repo-identity) nident=$2; shift 2 ;;
      --branch) nbranch=$2; shift 2 ;;
      --mode) nmode=$2; shift 2 ;;
      --scope) nscope=$2; have_scope=1; shift 2 ;;
      *) shift ;;
    esac
  done
  local ohead obase oident obranch omode oscope reason=''
  ohead=$(jq -r '.headSha // ""' "$path")
  obase=$(jq -r '.baseSha // ""' "$path")
  oident=$(jq -r '.repository.identity // ""' "$path")
  obranch=$(jq -r '.branch // ""' "$path")
  omode=$(jq -r '.deliveryMode // ""' "$path")
  oscope=$(jq -r '(.approvedScope // []) | join(",")' "$path")
  local frozen; frozen=$(jq -r '.frozen.sha // ""' "$path")

  [ -n "$nhead" ] && [ -n "$frozen" ] && [ "$nhead" != "$frozen" ] && reason="branch head moved from frozen candidate $frozen to $nhead"
  [ -n "$nbase" ] && [ "$nbase" != "$obase" ] && reason="${reason:+$reason; }base SHA changed from $obase to $nbase"
  [ -n "$nident" ] && [ "$nident" != "$oident" ] && reason="${reason:+$reason; }repository identity changed from $oident to $nident"
  [ -n "$nbranch" ] && [ "$nbranch" != "$obranch" ] && reason="${reason:+$reason; }canonical branch changed from $obranch to $nbranch"
  [ -n "$nmode" ] && [ "$nmode" != "$omode" ] && reason="${reason:+$reason; }delivery mode changed from $omode to $nmode"
  [ "$have_scope" = 1 ] && [ "$nscope" != "$oscope" ] && reason="${reason:+$reason; }approved scope changed"

  local now; now=$(fm_gov_now)
  # Apply the observed values first.
  jq --arg h "${nhead:-$ohead}" --arg b "${nbase:-$obase}" --arg i "${nident:-$oident}" \
     --arg br "${nbranch:-$obranch}" --arg m "${nmode:-$omode}" \
     '.headSha=$h | .baseSha=$b | .repository.identity=$i | .branch=$br
      | .deliveryMode=(if $m=="" then null else $m end)' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
  if [ "$have_scope" = 1 ]; then
    local scope_json; scope_json=$(printf '%s' "$nscope" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc .)
    jq --argjson s "$scope_json" '.approvedScope=$s' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
  fi

  if [ -n "$reason" ]; then
    jq --arg r "$reason" --arg n "$now" '
      .frozen={sha:null, at:null} | .review={sha:null, verdict:null, at:null}
      | .qa={sha:null, verdict:null, at:null} | .captainAuth={sha:null, ref:null, at:null}
      | .landingReady=false | .invalidation={reason:$r, at:$n}
      | .history += [{ts:$n, event:"invalidate", detail:$r}]' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    fm_gov_audit "$task" invalidate "$reason"
  fi
  return 0
}

# Recompute landingReady: valid iff frozen==review.sha==qa.sha==captainAuth.sha==headSha,
# all set, review & qa verdicts pass, and no pending invalidation.
fm_gov_record_recompute_landing() {  # <task>
  fm_gov_require_jq || return 2
  local path; path=$(fm_gov_record_path "$1")
  [ -f "$path" ] || return 1
  jq '
    (.frozen.sha) as $f | (.review.sha) as $r | (.qa.sha) as $q
    | (.captainAuth.sha) as $c | (.headSha) as $h | (.invalidation.reason) as $inv
    | .landingReady = (
        ($f != null) and ($f == $r) and ($f == $q) and ($f == $c) and ($f == $h)
        and (.review.verdict == "pass") and (.qa.verdict == "pass") and ($inv == null))
  ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
}

# 0 iff Captain authorization is currently valid for <current-head>: the exact SHA
# is authorized, reviewed pass, QA pass, and no invalidation. This is the one
# authorization predicate; a different head (descendant, tree-match, squash) has a
# different SHA and therefore fails.
fm_gov_auth_valid() {  # <task> <current-head>
  fm_gov_require_jq || return 2
  local task=$1 head=$2 path; path=$(fm_gov_record_path "$task")
  [ -f "$path" ] || return 1
  local auth rv qv inv
  auth=$(jq -r '.captainAuth.sha // ""' "$path")
  rv=$(jq -r '.review.verdict // ""' "$path")
  qv=$(jq -r '.qa.verdict // ""' "$path")
  inv=$(jq -r '.invalidation.reason // ""' "$path")
  [ -n "$auth" ] && [ "$auth" = "$head" ] && [ "$rv" = pass ] && [ "$qv" = pass ] && [ -z "$inv" ] \
    && [ "$(jq -r '.qa.sha // ""' "$path")" = "$head" ] && [ "$(jq -r '.review.sha // ""' "$path")" = "$head" ]
}

# --- pre-QA gate ordering (Scope D) ----------------------------------------

# 0 iff every pre-QA field is satisfied so FINAL independent QA may dispatch.
# Reads the record plus explicit runtime facts the record does not hold (tree
# clean, no mutating process). Prints the first unmet gate on stderr and returns 1.
# Args: --task T --tree-clean 0|1 --no-mutating-process 0|1 [--tests-recorded 0|1]
fm_gov_preqa_ready() {
  local task='' tree_clean='' no_mut='' tests_ovr=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=$2; shift 2 ;;
      --tree-clean) tree_clean=$2; shift 2 ;;
      --no-mutating-process) no_mut=$2; shift 2 ;;
      --tests-recorded) tests_ovr=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  fm_gov_require_jq || return 2
  local path; path=$(fm_gov_record_path "$task")
  [ -f "$path" ] || { echo "PRE-QA BLOCKED: no governance record for $task" >&2; return 1; }
  local mode base branch repo frozen review tests
  mode=$(jq -r '.deliveryMode // ""' "$path")
  base=$(jq -r '.baseSha // ""' "$path")
  branch=$(jq -r '.branch // ""' "$path")
  repo=$(jq -r '.repository.identity // ""' "$path")
  frozen=$(jq -r '.frozen.sha // ""' "$path")
  review=$(jq -r '.review.verdict // ""' "$path")
  tests=${tests_ovr:-$(jq -r 'if (.evidence // []) | any(. | test("test"; "i")) then 1 else 0 end' "$path")}
  local unresolved
  unresolved=$(jq -r '.classification.unresolvedFindings // 0' "$path")

  [ -n "$mode" ] || { echo "PRE-QA BLOCKED: delivery mode not resolved for $task" >&2; return 1; }
  { [ -n "$base" ] && [ -n "$branch" ] && [ -n "$repo" ]; } || { echo "PRE-QA BLOCKED: repository/base/branch not fully resolved for $task" >&2; return 1; }
  [ "$review" = pass ] || { echo "PRE-QA BLOCKED: independent review is not complete/pass for $task (got '${review:-none}')" >&2; return 1; }
  [ "${unresolved:-0}" = 0 ] || { echo "PRE-QA BLOCKED: $unresolved unresolved actionable finding(s) remain for $task" >&2; return 1; }
  [ "$tests" = 1 ] || { echo "PRE-QA BLOCKED: required tests not recorded for $task" >&2; return 1; }
  [ "$tree_clean" = 1 ] || { echo "PRE-QA BLOCKED: working tree not clean for $task" >&2; return 1; }
  [ "$no_mut" = 1 ] || { echo "PRE-QA BLOCKED: a branch-mutating process is still live for $task (freeze not safe)" >&2; return 1; }
  [ -n "$frozen" ] || { echo "PRE-QA BLOCKED: candidate not frozen at an exact SHA for $task" >&2; return 1; }
  return 0
}

# --- crew freeze / process classification (Scope F) ------------------------

# Classify a single process by its command string. Prints one of:
#   coding-agent | login-shell | dead | unrelated
# The harness set mirrors bin/fm-spawn.sh's verified adapters plus the memory CLI.
fm_gov_classify_process() {  # <command-string>
  local cmd=$1
  [ -n "$cmd" ] || { printf 'dead'; return; }
  case "$cmd" in
    *claude*|*codex*|*opencode*|*' pi '*|pi\ *|*grok*|*gemini*|*mem.mjs*|*'no-mistakes'*|*'axi run'*)
      printf 'coding-agent'; return ;;
  esac
  # A bare interactive/login shell with no agent is inert.
  case "$cmd" in
    -bash|bash|-sh|sh|-zsh|zsh|*/bash|*/zsh|*/sh|'bash -l'|'bash -i')
      printf 'login-shell'; return ;;
  esac
  printf 'unrelated'
}

# --- local-only governance gate field validation (Scope G) -----------------

# 0 iff every field a local-only landing must record is present and consistent, and
# no remote action is requested. This is the local counterpart to no-mistakes' PR
# gate; it shares this library with the PR path. On failure prints the missing/bad
# field to stderr and returns 1.
# Args: --task T --repo R --base SHA --candidate SHA --tree-clean 0|1
#       --tests-pass 0|1 --review-pass 0|1 --unresolved N --qa-pass 0|1
#       --captain-sha SHA --merge-method M --text-file F
fm_gov_local_gate_ready() {
  local task='' repo='' base='' cand='' tree='' tests='' review='' unresolved='0'
  local qa='' captain_sha='' method='' text_file=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=$2; shift 2 ;;
      --repo) repo=$2; shift 2 ;;
      --base) base=$2; shift 2 ;;
      --candidate) cand=$2; shift 2 ;;
      --tree-clean) tree=$2; shift 2 ;;
      --tests-pass) tests=$2; shift 2 ;;
      --review-pass) review=$2; shift 2 ;;
      --unresolved) unresolved=$2; shift 2 ;;
      --qa-pass) qa=$2; shift 2 ;;
      --captain-sha) captain_sha=$2; shift 2 ;;
      --merge-method) method=$2; shift 2 ;;
      --text-file) text_file=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  local text=''
  [ -n "$text_file" ] && [ -f "$text_file" ] && text=$(cat "$text_file")
  # A local-only gate must NEVER carry a remote instruction.
  if [ -n "$text" ] && fm_gov_text_requests_remote "$text"; then
    echo "LOCAL-GATE BLOCKED: a push/PR instruction was found in the task text; local-only never touches a remote or PR." >&2
    return 1
  fi
  [ -n "$repo" ] || { echo "LOCAL-GATE BLOCKED: exact repository not recorded" >&2; return 1; }
  [ -n "$base" ] || { echo "LOCAL-GATE BLOCKED: exact base SHA not recorded" >&2; return 1; }
  [ -n "$cand" ] || { echo "LOCAL-GATE BLOCKED: exact candidate SHA not recorded" >&2; return 1; }
  [ "$tree" = 1 ] || { echo "LOCAL-GATE BLOCKED: working tree not clean" >&2; return 1; }
  [ "$tests" = 1 ] || { echo "LOCAL-GATE BLOCKED: required test result not recorded/passing" >&2; return 1; }
  [ "$review" = 1 ] || { echo "LOCAL-GATE BLOCKED: independent review not complete/passing" >&2; return 1; }
  [ "${unresolved:-0}" = 0 ] || { echo "LOCAL-GATE BLOCKED: $unresolved unresolved actionable finding(s)" >&2; return 1; }
  [ "$qa" = 1 ] || { echo "LOCAL-GATE BLOCKED: exact-SHA QA not passing" >&2; return 1; }
  [ -n "$captain_sha" ] || { echo "LOCAL-GATE BLOCKED: exact-SHA Captain authorization not recorded" >&2; return 1; }
  if [ "$captain_sha" != "$cand" ]; then
    echo "LOCAL-GATE BLOCKED: Captain-authorized SHA $captain_sha does not equal candidate $cand" >&2
    return 1
  fi
  [ -n "$method" ] || { echo "LOCAL-GATE BLOCKED: permitted local merge method not recorded" >&2; return 1; }
  return 0
}
