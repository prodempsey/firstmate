import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Parent-side driver for the Bridge/Helm projection-consumer child processes (Q1). It
// spawns each surface as a REAL separate process (project-consumer.mjs), which renders the
// `cp project` output into a durable board dir, then reads that board back. Keeping the
// render out-of-process is what makes "Bridge and Helm cite the same projection
// revision/checksum" and "zero orphan Bridge cards" claims about actual processes rather
// than an in-memory function call.

const PROJECT_CONSUMER = fileURLToPath(new URL('./project-consumer.mjs', import.meta.url));

// Run one projection-consumer child for `surface` against `dataDir` (optionally pinned to
// `revision`), rendering into `boardDir`. Returns { pid, manifest, projection }.
export function runProjectionConsumer({ surface, dataDir, boardDir, revision = null }) {
  const env = { ...process.env, CP_DATA_DIR: dataDir, CP_SURFACE: surface, CP_BOARD_DIR: boardDir };
  if (revision !== null) env.CP_REVISION = String(revision);
  const res = spawnSync('node', [PROJECT_CONSUMER], { encoding: 'utf8', env });
  if (res.status !== 0) throw new Error(`projection consumer (${surface}) failed: ${res.stderr}`);
  const projection = JSON.parse(res.stdout.trim());
  const manifest = JSON.parse(fs.readFileSync(path.join(boardDir, surface, 'manifest.json'), 'utf8'));
  return { pid: res.pid, manifest, projection };
}

// The task ids currently rendered as card files on the Bridge board (the durable board
// state, independent of the last projection object).
export function boardCardIds(boardDir) {
  const cardsDir = path.join(boardDir, 'bridge', 'cards');
  if (!fs.existsSync(cardsDir)) return [];
  return fs.readdirSync(cardsDir).filter((f) => f.endsWith('.card.json')).map((f) => f.replace(/\.card\.json$/, ''));
}

// The live-pane task ids on the Helm board.
export function boardLiveIds(boardDir) {
  const liveFile = path.join(boardDir, 'helm', 'live.json');
  if (!fs.existsSync(liveFile)) return [];
  return JSON.parse(fs.readFileSync(liveFile, 'utf8')).map((p) => p.task_id);
}
