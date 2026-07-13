#!/usr/bin/env bash
# fm-trunk-check.sh - verify the CANONICAL TRUNK INVARIANT for governed projects.
#
# WHY THIS EXISTS
# ---------------
# A governed repo's `main` sat frozen for sixteen days and nobody noticed; it was
# found by accident when a finished branch would not merge. The repo was
# converged, and the drift RECURRED within hours - firstmate landed the next
# branch into the serving worktree out of habit, trunk fell a commit behind, and
# again nothing detected it. Both a written rule and a reminder already existed
# and both failed, so this is a verifier, not a note: an instruction that can be
# silently skipped eventually is.
#
# THE DECLARATION (the input, and why it lives where it lives)
# ------------------------------------------------------------
# The canonical trunk of each governed project is declared in ONE machine-readable
# file, OUTSIDE the governed repo: the firstmate home's
# config/canonical-trunk.json (local, gitignored; FM_CANONICAL_TRUNK overrides the
# path). A repo cannot be the authority on its own canonicity: a declaration that
# rides the governed lineage drifts with it, is rewritten by the same reset or
# force-push it is meant to catch, and dies with the exact failure it guards
# against. This declaration lives on firstmate's governance lineage instead - a
# different repo entirely for every project clone, and untracked config even when
# firstmate governs itself - so no ref operation inside a governed repo can move,
# stale, or orphan it. docs/configuration.md "Canonical trunk declaration" owns
# the schema; this script owns the verification.
#
# ABSENCE IS AN ERROR, NEVER A PASS. A missing file, a project registered in
# data/projects.md but absent from the declaration, a malformed entry, or an
# unreadable observation all exit 2 with a loud error. A verifier that cannot
# read its input must say so, not report health.
#
# WHAT IT COMPARES (all read-only; this script NEVER writes a ref, branch, or
# config - detect, refuse, name the fix; a verifier that silently moves refs is a
# new way to lose work)
#   declared canonical trunk   the declared branch in the declared checkout
#   GitHub default branch      the clone's cached origin/HEAD
#   running process            branch + SHA of what is actually being served,
#                              read from the project's own machine-readable
#                              identity command (fleet-bridge: bin/serving-root.sh
#                              identity) or from the declared serving worktree
#   primary checkout           what the trunk checkout actually has on HEAD
#   crewmate provisioning base the commit new crew worktrees are cut from
#
# THE RULE
#   The serving commit must be EQUAL TO or an ANCESTOR OF canonical trunk.
#   Serving behind trunk  = deploy lag: tolerable, reported, exit 0.
#   Serving ahead of, or divergent from, trunk = THE DRIFT BUG: exit 1.
#
# Usage:
#   fm-trunk-check.sh [--all | <project>] [--json | --lines] [-q]
#     --all       every declared project, plus every project registered in
#                 data/projects.md (an undeclared one is an error). Default.
#     <project>   one project by registry name.
#     --json      stable machine-readable report (consumed by fm-merge-local.sh
#                 and fm-fleet-view.sh).
#     --lines     ready-made "TRUNK: ..." diagnostic lines for bootstrap.
#     -q          suppress the human report; exit code only.
#
# Exit: 0 healthy (SILENT - silence is the normal state) or deploy lag (one NOTE
#       line), 1 drift, 2 declaration or observation error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DECL="${FM_CANONICAL_TRUNK:-$CONFIG/canonical-trunk.json}"
REGISTRY="$DATA/projects.md"
# Bound the project's own identity command so a wedged serving process can never
# stall startup or a merge; a timeout is an observation error, not a pass.
SERVING_TIMEOUT=${FM_TRUNK_SERVING_TIMEOUT:-5}

TARGET=--all
FORMAT=text
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '/^# Usage:/,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    --all) TARGET=--all ;;
    --json) FORMAT=json ;;
    --lines) FORMAT=lines ;;
    -q|--quiet) QUIET=1 ;;
    -*) echo "fm-trunk-check: unknown option $1" >&2; exit 2 ;;
    *) TARGET=$1 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-trunk-check: jq not found; the canonical-trunk declaration cannot be read" >&2; exit 2; }

# A leading ~ in a declared path means $HOME (the declaration is hand-written).
# The tilde is held in a variable so it is matched literally, never expanded.
expand_home() {
  local path=$1 tilde='~'
  case "$path" in
    "$tilde") printf '%s\n' "$HOME" ;;
    "$tilde"/*) printf '%s\n' "$HOME/${path#"$tilde"/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

# --- findings ---------------------------------------------------------------
#
# Findings accumulate as TAB-separated records: <project> <severity> <code>
# <message> <fix>. Severity drives the exit code: error > drift > note > ok.
# Message and fix are always single-line, because the record separator is a
# newline; the multi-line declaration template is printed separately.

FINDINGS=""
WORST=ok
NEEDS_TEMPLATE=0
add_finding() {
  local project=$1 severity=$2 code=$3 message=$4 fix=${5:-}
  case "$code" in declaration-absent|declaration-invalid|declaration-malformed) NEEDS_TEMPLATE=1 ;; esac
  FINDINGS="$FINDINGS$project	$severity	$code	$message	$fix
"
  case "$severity" in
    error) WORST=error ;;
    drift) [ "$WORST" = error ] || WORST=drift ;;
    note) case "$WORST" in error|drift) ;; *) WORST=note ;; esac ;;
  esac
}

exit_code_for() {
  case "$1" in
    error) echo 2 ;;
    drift) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Per-project observation record, JSON, accumulated for --json.
REPORTS=""
add_report() { REPORTS="$REPORTS$1
"; }

# --- declaration ------------------------------------------------------------

# Registry names from data/projects.md ("- <name> [<mode>] - <desc>"), the
# INDEPENDENT list of what must be declared. Cross-checking against it is what
# closes the delete-the-declaration hole: a governed project that vanishes from
# the declaration is still named here, and still errors.
registry_projects() {
  [ -f "$REGISTRY" ] || return 0
  awk '$1=="-" && $2 ~ /^[A-Za-z0-9._-]+$/ {print $2}' "$REGISTRY"
}

declared_projects() {
  jq -r '.projects | keys[]' "$DECL" 2>/dev/null || true
}

# Echo one project's declaration entry as compact JSON, or fail with the reason.
# Required: trunk_branch, trunk_checkout, and an EXPLICIT serving.source of
# command|worktree|none. Requiring the serving key even when nothing serves the
# repo is deliberate: an omitted key is exactly the silent gap this exists to
# close, so "nothing serves this" must be said out loud, once, in the file.
declaration_for() {
  local project=$1
  jq -e --arg p "$project" '
    .projects[$p]
    | if type != "object" then error("entry is not an object")
      elif (.trunk_branch // "") == "" then error("missing trunk_branch")
      elif (.trunk_checkout // "") == "" then error("missing trunk_checkout")
      elif (.serving | type) != "object" then error("missing serving (declare source: command|worktree|none)")
      elif (.serving.source // "") == "" then error("missing serving.source")
      elif (.serving.source | IN("command","worktree","none") | not) then error("serving.source must be command, worktree, or none")
      elif (.serving.source == "command" and (.serving.command // "") == "") then error("serving.source=command needs serving.command")
      elif (.serving.source == "worktree" and (.serving.worktree // "") == "") then error("serving.source=worktree needs serving.worktree")
      else . end
  ' "$DECL" 2>&1
}

# Printed verbatim whenever a declaration finding fires, so the exact fix is
# always in front of whoever hit it.
print_declaration_template() {
  cat >&2 <<EOF

Declare each governed project's canonical trunk in $DECL
(docs/configuration.md "Canonical trunk declaration" owns the schema):

{
  "schema": "firstmate/canonical-trunk/1",
  "projects": {
    "<project>": {
      "trunk_branch": "main",
      "trunk_checkout": "~/fleet/<project>",
      "provisioning_base": "main",
      "serving": { "source": "none", "why": "no running process serves this repo" }
    }
  }
}

serving.source is required and explicit: "command" (run the project's own identity
command, e.g. bin/serving-root.sh identity), "worktree" (read the serving checkout's
git HEAD directly), or "none" (nothing serves this repo).
EOF
}

# --- per-project verification ----------------------------------------------

# git plumbing, read-only. Every helper here is a query; none writes.
git_sha()     { git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null; }
git_head_sha(){ git -C "$1" rev-parse --verify --quiet HEAD 2>/dev/null; }
git_branch()  { git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null; }
git_has()     { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; }
git_is_ancestor() { git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null; }
short() { printf '%s\n' "${1:0:12}"; }

# Read the serving branch/SHA from the project's OWN machine-readable identity.
# This is the boundary with the serving-root work: firstmate consumes that
# contract, it does not re-derive it. Echoes "<branch>\t<sha>\t<dirty>" or fails
# with a reason on stdout.
serving_identity() {
  local source=$1 command=$2 worktree=$3 out branch sha dirty
  case "$source" in
    command)
      if command -v timeout >/dev/null 2>&1; then
        out=$(timeout "$SERVING_TIMEOUT" sh -c "$command" 2>&1) || {
          printf 'serving identity command failed (exit %s): %s\n' "$?" "$(printf '%s' "$out" | head -1)"
          return 1
        }
      else
        out=$(sh -c "$command" 2>&1) || {
          printf 'serving identity command failed: %s\n' "$(printf '%s' "$out" | head -1)"
          return 1
        }
      fi
      # Accept the documented identity shape, tolerating a leading log line.
      out=$(printf '%s\n' "$out" | grep -m1 '^[[:space:]]*{' || true)
      printf '%s' "$out" | jq -e . >/dev/null 2>&1 || {
        printf 'serving identity command emitted no JSON object\n'
        return 1
      }
      sha=$(printf '%s' "$out" | jq -r '(.sha // .commit // .head // "") | tostring')
      branch=$(printf '%s' "$out" | jq -r '(.branch // "") | tostring')
      dirty=$(printf '%s' "$out" | jq -r 'if .dirty == true then "true" else "false" end')
      [ -n "$sha" ] && [ "$sha" != null ] || { printf 'serving identity JSON has no sha\n'; return 1; }
      ;;
    worktree)
      [ -d "$worktree" ] || { printf 'serving worktree does not exist: %s\n' "$worktree"; return 1; }
      sha=$(git_head_sha "$worktree") || { printf 'serving worktree is not a git checkout: %s\n' "$worktree"; return 1; }
      branch=$(git_branch "$worktree" || true)
      if [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null | head -1)" ]; then dirty=true; else dirty=false; fi
      ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\t%s\n' "$branch" "$sha" "$dirty"
}

# Verify one project. Appends findings and one JSON report.
check_project() {
  local project=$1 entry err
  entry=$(declaration_for "$project") || {
    err=$(printf '%s' "$entry" | sed -e 's/^jq: error[^:]*: //' -e 's/ at <stdin>.*$//' | head -1)
    [ -n "$err" ] || err="no entry"
    add_finding "$project" error declaration-invalid \
      "declaration for '$project' in $DECL is missing or malformed: $err" \
      "add or repair the '$project' entry in $DECL (schema below)"
    add_report "$(jq -nc --arg p "$project" '{project:$p,status:"error",declared:false}')"
    return
  }

  local trunk_branch trunk_checkout prov_branch serving_source serving_command serving_worktree gh_declared
  trunk_branch=$(printf '%s' "$entry" | jq -r '.trunk_branch')
  trunk_checkout=$(expand_home "$(printf '%s' "$entry" | jq -r '.trunk_checkout')")
  prov_branch=$(printf '%s' "$entry" | jq -r '.provisioning_base // .trunk_branch')
  serving_source=$(printf '%s' "$entry" | jq -r '.serving.source')
  serving_command=$(expand_home "$(printf '%s' "$entry" | jq -r '.serving.command // ""')")
  serving_worktree=$(expand_home "$(printf '%s' "$entry" | jq -r '.serving.worktree // ""')")
  gh_declared=$(printf '%s' "$entry" | jq -r '.github_default // ""')

  # OBSERVATION 1: the declared canonical trunk.
  if ! git -C "$trunk_checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    add_finding "$project" error trunk-checkout-missing \
      "declared trunk checkout is not a git work tree: $trunk_checkout" \
      "correct trunk_checkout for '$project' in $DECL, or restore that checkout"
    add_report "$(jq -nc --arg p "$project" '{project:$p,status:"error",declared:true}')"
    return
  fi
  local trunk_sha
  trunk_sha=$(git_sha "$trunk_checkout" "refs/heads/$trunk_branch") || {
    add_finding "$project" error trunk-branch-missing \
      "declared canonical trunk branch '$trunk_branch' does not exist in $trunk_checkout" \
      "correct trunk_branch for '$project' in $DECL, or restore the branch"
    add_report "$(jq -nc --arg p "$project" '{project:$p,status:"error",declared:true}')"
    return
  }

  # OBSERVATION 2: the GitHub default branch (the clone's cached origin/HEAD - a
  # local read, so this stays cheap enough for startup and every merge).
  local gh_default
  gh_default=$(git -C "$trunk_checkout" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  gh_default=${gh_default#origin/}
  if [ -n "$gh_default" ] && [ "$gh_default" != "$trunk_branch" ]; then
    add_finding "$project" drift github-default-disagrees \
      "GitHub default branch is '$gh_default' but the declared canonical trunk is '$trunk_branch'" \
      "reconcile the two: change the default branch on GitHub, or correct trunk_branch in $DECL"
  fi
  if [ -n "$gh_declared" ] && [ -n "$gh_default" ] && [ "$gh_declared" != "$gh_default" ]; then
    add_finding "$project" drift github-default-unexpected \
      "declared github_default '$gh_declared' but origin/HEAD says '$gh_default'" \
      "refresh origin/HEAD (git -C $trunk_checkout remote set-head origin -a) or correct the declaration"
  fi

  # OBSERVATION 3: the primary checkout - what the trunk clone actually has out.
  # Crew worktrees and every local landing assume this is the canonical trunk.
  local primary_branch primary_sha
  primary_branch=$(git_branch "$trunk_checkout" || true)
  primary_sha=$(git_head_sha "$trunk_checkout" || true)
  if [ -z "$primary_branch" ]; then
    add_finding "$project" drift primary-detached \
      "the trunk checkout $trunk_checkout is on a detached HEAD, not canonical trunk '$trunk_branch'" \
      "git -C $trunk_checkout checkout $trunk_branch"
  elif [ "$primary_branch" != "$trunk_branch" ]; then
    add_finding "$project" drift primary-off-trunk \
      "the trunk checkout $trunk_checkout is on '$primary_branch', not canonical trunk '$trunk_branch'" \
      "git -C $trunk_checkout checkout $trunk_branch"
  fi

  # OBSERVATION 4: the crewmate provisioning base - the commit new crew worktrees
  # are cut from. A base behind trunk quietly bases every new task on stale code.
  local prov_sha
  prov_sha=$(git_sha "$trunk_checkout" "refs/heads/$prov_branch" || true)
  if [ -z "$prov_sha" ]; then
    add_finding "$project" error provisioning-base-missing \
      "declared crewmate provisioning base '$prov_branch' does not exist in $trunk_checkout" \
      "correct provisioning_base for '$project' in $DECL"
  elif [ "$prov_sha" != "$trunk_sha" ]; then
    add_finding "$project" drift provisioning-base-off-trunk \
      "crewmate provisioning base '$prov_branch' is at $(short "$prov_sha"), canonical trunk '$trunk_branch' is at $(short "$trunk_sha")" \
      "new crew worktrees would be cut off trunk; reconcile '$prov_branch' with '$trunk_branch' in $trunk_checkout"
  fi

  # OBSERVATION 5: the running process. Read from the project's own identity
  # contract; never re-derived here.
  local serving_branch='' serving_sha='' serving_dirty=false relation=none ident
  if [ "$serving_source" != none ]; then
    if ! ident=$(serving_identity "$serving_source" "$serving_command" "$serving_worktree"); then
      add_finding "$project" error serving-unreadable \
        "cannot read the serving lineage for '$project': $(printf '%s' "$ident" | head -1)" \
        "fix the declared serving source in $DECL, or the process that publishes it"
      relation=unreadable
    else
      serving_branch=$(printf '%s' "$ident" | cut -f1)
      serving_sha=$(printf '%s' "$ident" | cut -f2)
      serving_dirty=$(printf '%s' "$ident" | cut -f3)

      # THE RULE: serving must be equal to, or an ancestor of, canonical trunk.
      if ! git_has "$trunk_checkout" "$serving_sha"; then
        relation=unknown-commit
        add_finding "$project" drift serving-unknown-commit \
          "the serving commit $(short "$serving_sha") is not present in the trunk repository at all - the serving lineage has left the governed repo" \
          "land the serving lineage into '$trunk_branch' (git -C $trunk_checkout merge --ff-only <branch>) or restore serving to a trunk commit"
      elif [ "$serving_sha" = "$trunk_sha" ]; then
        relation=equal
      elif git_is_ancestor "$trunk_checkout" "$serving_sha" "$trunk_sha"; then
        relation=behind
        add_finding "$project" note serving-behind-trunk \
          "deploy lag: serving $(short "$serving_sha") is behind canonical trunk '$trunk_branch' $(short "$trunk_sha")" \
          "redeploy, or fast-forward the serving checkout to '$trunk_branch' when the captain approves"
      elif git_is_ancestor "$trunk_checkout" "$trunk_sha" "$serving_sha"; then
        relation=ahead
        add_finding "$project" drift serving-ahead-of-trunk \
          "TRUNK DRIFT: the serving lineage $(short "$serving_sha")${serving_branch:+ ($serving_branch)} is AHEAD of canonical trunk '$trunk_branch' $(short "$trunk_sha") - work was landed into the serving checkout instead of trunk" \
          "land it on trunk: git -C $trunk_checkout merge --ff-only $(if [ -n "$serving_branch" ] && [ "$serving_branch" != HEAD ]; then printf '%s' "$serving_branch"; else short "$serving_sha"; fi)"
      else
        relation=diverged
        add_finding "$project" drift serving-diverged \
          "TRUNK DRIFT: the serving lineage $(short "$serving_sha")${serving_branch:+ ($serving_branch)} has DIVERGED from canonical trunk '$trunk_branch' $(short "$trunk_sha")" \
          "reconcile the two lineages by hand; firstmate will not move refs for you"
      fi
      if [ "$serving_dirty" = true ]; then
        add_finding "$project" note serving-dirty \
          "the serving checkout has uncommitted changes, so the live process is not exactly any commit" \
          "commit or discard them in the serving checkout"
      fi
    fi
  fi

  add_report "$(jq -nc \
    --arg p "$project" \
    --arg tb "$trunk_branch" --arg tc "$trunk_checkout" --arg ts "$trunk_sha" \
    --arg gh "$gh_default" \
    --arg pb "$primary_branch" --arg ps "$primary_sha" \
    --arg vb "$prov_branch" --arg vs "$prov_sha" \
    --arg ss "$serving_source" --arg sb "$serving_branch" --arg sv "$serving_sha" \
    --arg sd "$serving_dirty" --arg rel "$relation" \
    '{project:$p,declared:true,
      trunk:{branch:$tb,checkout:$tc,sha:$ts},
      github_default:(if $gh == "" then null else $gh end),
      primary_checkout:{branch:(if $pb == "" then null else $pb end),sha:(if $ps == "" then null else $ps end)},
      provisioning_base:{branch:$vb,sha:(if $vs == "" then null else $vs end)},
      serving:{source:$ss,
               branch:(if $sb == "" then null else $sb end),
               sha:(if $sv == "" then null else $sv end),
               dirty:($sd == "true"),
               relation:$rel}}')"
}

# --- run --------------------------------------------------------------------

if [ ! -f "$DECL" ]; then
  # No declaration at all. This is an ERROR, not a quiet default - but a home with
  # no projects has nothing to govern yet, so it stays silent.
  if [ -n "$(registry_projects)" ]; then
    add_finding '-' error declaration-absent \
      "no canonical-trunk declaration at $DECL - trunk drift is NOT being verified for any project" \
      "declare every governed project's canonical trunk in $DECL (schema below)"
  fi
elif ! jq -e '.projects | type == "object"' "$DECL" >/dev/null 2>&1; then
  add_finding '-' error declaration-malformed \
    "the canonical-trunk declaration $DECL is malformed (not JSON, or has no .projects object)" \
    "repair it; docs/configuration.md 'Canonical trunk declaration' owns the schema"
else
  if [ "$TARGET" = --all ]; then
    # Union of declared projects and registered ones: a registered project with no
    # declaration is an error (it is governed but unverified), and a declared
    # project is checked even if it is not in the registry.
    projects=$(
      { declared_projects; registry_projects; } | LC_ALL=C sort -u
    )
    for p in $projects; do
      check_project "$p"
    done
  else
    check_project "$TARGET"
  fi
fi

CODE=$(exit_code_for "$WORST")

if [ "$FORMAT" = json ]; then
  printf '%s' "$REPORTS" | jq -sc \
    --arg status "$WORST" \
    --arg decl "$DECL" \
    --argjson findings "$(
      printf '%s' "$FINDINGS" | jq -Rsc '
        split("\n") | map(select(length > 0) | split("\t")
        | {project:.[0],severity:.[1],code:.[2],message:.[3],fix:.[4]})'
    )" \
    '{schema:"firstmate/canonical-trunk-check/1",declaration:$decl,status:$status,findings:$findings,projects:.}'
  exit "$CODE"
fi

[ "$QUIET" = 1 ] && exit "$CODE"

if [ "$FORMAT" = lines ]; then
  # One "TRUNK: ..." line per finding, for the bootstrap diagnostics surface.
  # Healthy is silent.
  printf '%s' "$FINDINGS" | while IFS='	' read -r project severity code message fix; do
    [ -n "${code:-}" ] || continue
    if [ "$project" = - ]; then
      printf 'TRUNK: %s: %s%s\n' "$severity" "$message" "${fix:+ - fix: $(printf '%s' "$fix" | head -1)}"
    else
      printf 'TRUNK: %s: %s: %s%s\n' "$project" "$severity" "$message" "${fix:+ - fix: $(printf '%s' "$fix" | head -1)}"
    fi
  done
  exit "$CODE"
fi

# Human report. Silence on a clean fleet.
if [ "$WORST" != ok ]; then
  printf '%s' "$FINDINGS" | while IFS='	' read -r project severity code message fix; do
    [ -n "${code:-}" ] || continue
    case "$severity" in
      error) label='ERROR' ;;
      drift) label='DRIFT' ;;
      *) label='NOTE ' ;;
    esac
    if [ "$project" = - ]; then
      printf '%s %s\n' "$label" "$message" >&2
    else
      printf '%s [%s] %s\n' "$label" "$project" "$message" >&2
    fi
    [ -n "${fix:-}" ] && printf '      fix: %s\n' "$fix" >&2
  done
  [ "$NEEDS_TEMPLATE" = 1 ] && print_declaration_template
fi
exit "$CODE"
