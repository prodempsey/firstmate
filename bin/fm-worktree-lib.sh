# shellcheck shell=bash
# Shared worktree-path predicates for spawn and teardown safety gates.
# Usage: . bin/fm-worktree-lib.sh

# True when $1 looks like a treehouse pool slot (portable: path contains
# `/.treehouse/`). Callers combine this with repository-membership checks so a
# similarly named directory cannot qualify on its path alone.
is_under_treehouse_pool() {  # <abs-path>
  case "$1" in
    */.treehouse/*|*/.treehouse) return 0 ;;
    *) return 1 ;;
  esac
}
