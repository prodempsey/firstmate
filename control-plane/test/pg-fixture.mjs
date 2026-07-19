import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Test-only ephemeral Postgres fixture (spec section 2.1 / workflow 10): a real,
// multi-connection Postgres server started in a temp datadir on a local port,
// used ONLY to run the storage-seam contract against a genuinely different engine
// than PGlite. Nothing production is touched; stop() tears down the exact instance
// this fixture started and removes its temp datadir.
//
// Returns null when the platform cannot run embedded-postgres, so the contract
// test can skip with a clear reason rather than failing on an unsupported host.
export async function startEmbeddedPostgres() {
  let EmbeddedPostgres;
  try {
    ({ default: EmbeddedPostgres } = await import('embedded-postgres'));
  } catch (error) {
    return { unavailable: `embedded-postgres not installed: ${error.message}` };
  }

  const databaseDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-s0-epg-'));
  // A high, mostly-unique port derived from the PID (tests run single-process).
  const port = 50000 + (process.pid % 12000);
  const user = 'cp';
  const password = 'cp';
  // embedded-postgres hard-codes --lc-messages=en_US.UTF-8, which many minimal
  // hosts (containers/CI) do not have installed. Append an always-available locale
  // so the later flag wins; otherwise initdb exits 1 on those hosts.
  const pg = new EmbeddedPostgres({
    databaseDir,
    user,
    password,
    port,
    persistent: false,
    initdbFlags: ['--lc-messages=C']
  });

  try {
    await pg.initialise();
    await pg.start();
  } catch (error) {
    try {
      await pg.stop();
    } catch {
      // ignore
    }
    fs.rmSync(databaseDir, { recursive: true, force: true });
    return { unavailable: `embedded-postgres failed to start: ${error.message}` };
  }

  const connString = `postgresql://${user}:${password}@localhost:${port}/postgres`;
  return {
    connString,
    async stop() {
      try {
        await pg.stop();
      } finally {
        fs.rmSync(databaseDir, { recursive: true, force: true });
      }
    }
  };
}
