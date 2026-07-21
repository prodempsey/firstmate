import fs from 'node:fs';
import path from 'node:path';
import { runVerb } from '../../lib/coordinator.mjs';

// Child-process entry for an isolated Bridge/Helm "process" (spec section 11; Q1 ruling:
// the spec's "isolated Bridge/Helm processes" is satisfied by fixture consumers of
// `cp project` output rendered into fixture readers as SEPARATE CHILD PROCESSES, without
// standing up the real cockpit server). This process invokes the SAME coordinator
// entrypoint the `cp` CLI uses (runVerb), takes the requested projection surface at a
// requested revision, and RENDERS it into a durable fixture board dir: one card/pane file
// per row plus a manifest recording the cited projection_revision + checksum. The runner
// then reads that board back to enforce the "one card per task", "same revision/checksum",
// and "zero orphan cards" assertions from a genuinely out-of-process render.
//
// Spawned as: node project-consumer.mjs   with env CP_DATA_DIR, CP_SURFACE, CP_BOARD_DIR,
// optional CP_REVISION. Prints the projection JSON to stdout and exits 0, or prints a
// typed error to stderr and exits 1.

async function main() {
  const dataDir = process.env.CP_DATA_DIR;
  const surface = process.env.CP_SURFACE;
  const boardDir = process.env.CP_BOARD_DIR;
  if (!dataDir || !boardDir || (surface !== 'bridge' && surface !== 'helm')) {
    throw new Error('project-consumer requires CP_DATA_DIR, CP_BOARD_DIR, and CP_SURFACE=bridge|helm');
  }
  const argv = ['project', surface, '--data-dir', dataDir];
  if (process.env.CP_REVISION) argv.push('--revision', process.env.CP_REVISION);
  const outcome = await runVerb(argv, { env: process.env });
  const projection = outcome.result;

  const surfaceDir = path.join(boardDir, surface);
  fs.mkdirSync(surfaceDir, { recursive: true });
  fs.writeFileSync(path.join(surfaceDir, 'manifest.json'), JSON.stringify({
    kind: projection.kind,
    projection_revision: projection.projection_revision,
    checksum: projection.checksum
  }));

  if (surface === 'bridge') {
    // Render one card file per Bridge card; then reconcile the board by removing any
    // previously-rendered card whose task is no longer in this projection. A leftover card
    // file with no matching card in the current projection is precisely an ORPHAN CARD, and
    // this reconcile is what a faithful cockpit consumer would do on each new revision.
    const cardsDir = path.join(surfaceDir, 'cards');
    fs.mkdirSync(cardsDir, { recursive: true });
    const present = new Set(projection.cards.map((c) => c.task_id));
    for (const f of fs.readdirSync(cardsDir)) {
      const id = f.replace(/\.card\.json$/, '');
      if (!present.has(id)) fs.rmSync(path.join(cardsDir, f), { force: true });
    }
    for (const card of projection.cards) {
      fs.writeFileSync(path.join(cardsDir, `${card.task_id}.card.json`), JSON.stringify(card));
    }
  } else {
    fs.writeFileSync(path.join(surfaceDir, 'live.json'), JSON.stringify(projection.live));
    fs.writeFileSync(path.join(surfaceDir, 'retained.json'), JSON.stringify(projection.retained));
    fs.writeFileSync(path.join(surfaceDir, 'orphan_inspector.json'), JSON.stringify(projection.orphan_inspector));
  }

  process.stdout.write(JSON.stringify(projection) + '\n');
}

main().catch((err) => {
  process.stderr.write(`${err?.message || String(err)}\n`);
  process.exit(1);
});
