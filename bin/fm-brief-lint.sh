#!/usr/bin/env bash
# Lint crewmate and secondmate briefs for hard-coded commercial model names.
# Briefs describe work by task and capability; routing owns concrete model selection.
# Usage: fm-brief-lint.sh [<file-or-glob>...]
#
# With no arguments, scans data/*/brief.md under the active firstmate home.
# Escape hatch: put "model-names-ok: <reason>" as the first line, or inside a leading YAML frontmatter block.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF'
Usage: fm-brief-lint.sh [<file-or-glob>...]

With no arguments, scans data/*/brief.md under the active firstmate home.
Put "model-names-ok: <reason>" as the first line, or inside a leading YAML frontmatter block, to skip a model-routing brief.
EOF
}

has_glob_chars() {
  case "$1" in
    *[\*\?\[]*) return 0 ;;
    *) return 1 ;;
  esac
}

FILES=()
declare -A SEEN=()

add_file() {
  local file=$1
  [ -f "$file" ] || return 0
  if [ -z "${SEEN[$file]+x}" ]; then
    FILES+=("$file")
    SEEN[$file]=1
  fi
}

expand_pattern() {
  local pattern=$1 match
  while IFS= read -r match; do
    add_file "$match"
  done < <(compgen -G "$pattern" | sort)
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$#" -eq 0 ]; then
  default_pattern="${DATA%/}/*/brief.md"
  expand_pattern "$default_pattern"
else
  for arg in "$@"; do
    if has_glob_chars "$arg"; then
      expand_pattern "$arg"
    else
      add_file "$arg"
    fi
  done
fi

found=0
errors=0

for file in "${FILES[@]}"; do
  perl - "$file" <<'PERL'
use strict;
use warnings;

my $file = shift @ARGV;
open my $fh, '<', $file or do {
  print STDERR "error: cannot read $file: $!\n";
  exit 2;
};
my @lines = <$fh>;

my $reason;
if (@lines && $lines[0] =~ /\Amodel-names-ok:\s*(.*?)\s*\z/i) {
  $reason = $1;
} elsif (@lines && $lines[0] =~ /\A---\s*\z/) {
  for (my $i = 1; $i < @lines; $i++) {
    last if $lines[$i] =~ /\A(?:---|\.\.\.)\s*\z/;
    if ($lines[$i] =~ /\Amodel-names-ok:\s*(.*?)\s*\z/i) {
      $reason = $1;
      last;
    }
  }
}

if (defined $reason) {
  $reason =~ s/\A\s+|\s+\z//g;
  $reason = 'no reason given' if $reason eq '';
  print "$file: skipped (model-names-ok: $reason)\n";
  exit 0;
}

my $model_name = qr{
  (?<![A-Za-z0-9_])
  (
    claude-(?:opus|sonnet|haiku|fable)(?:-[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*)?
    | gpt-[A-Za-z0-9][A-Za-z0-9._-]*
    | o[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?
    | opus
    | sonnet
    | haiku
    | fable
  )
  (?![A-Za-z0-9_])
}ix;

my $violations = 0;
for (my $i = 0; $i < @lines; $i++) {
  while ($lines[$i] =~ /$model_name/g) {
    print "$file:" . ($i + 1) . ":$1\n";
    $violations = 1;
  }
}

exit($violations ? 1 : 0);
PERL
  rc=$?
  case "$rc" in
    0) ;;
    1) found=1 ;;
    *) errors=1 ;;
  esac
done

if [ "$errors" -ne 0 ] || [ "$found" -ne 0 ]; then
  exit 1
fi

exit 0
