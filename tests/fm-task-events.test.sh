#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-events)
CLI="$TMP_ROOT/visibility.mjs"
LOG="$TMP_ROOT/args"
mkdir -p "$TMP_ROOT"
cat > "$CLI" <<'JS'
#!/usr/bin/env node
import { writeFileSync } from 'node:fs';
writeFileSync(process.env.FM_TEST_EVENT_LOG, process.argv.slice(2).join('\n'));
JS
FM_TEST_EVENT_LOG="$LOG" FM_VISIBILITY_CLI="$CLI" "$ROOT/bin/fm-task-events.sh" task-a1 landed outcome fm/task-a1 local-only deadbeef
assert_grep 'close' "$LOG" "writer should invoke close"
assert_grep '--sha' "$LOG" "code closeout should include SHA evidence"
pass "task event writer delegates closure to visibility CLI"
