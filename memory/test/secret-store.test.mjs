import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { readSecretPresence, readSecretValue, secretsPath } from '../lib/secret-store.mjs';

function tmpSecrets(obj) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-secretstore-'));
  if (obj) fs.writeFileSync(path.join(dir, 'secrets.json'), JSON.stringify(obj), { mode: 0o600 });
  return dir;
}

test('secretsPath honors MEM_SECRETS_PATH, then MEM_SECRETS_DIR, then ~/.fleet', () => {
  assert.equal(secretsPath({ MEM_SECRETS_PATH: '/x/y/s.json' }), path.resolve('/x/y/s.json'));
  assert.equal(secretsPath({ MEM_SECRETS_DIR: '/x/y' }), path.join(path.resolve('/x/y'), 'secrets.json'));
  assert.equal(secretsPath({ HOME: '/home/u' }), path.join('/home/u', '.fleet', 'secrets.json'));
});

test('readSecretPresence is boolean and never returns the value', () => {
  const dir = tmpSecrets({ openai: 'sk-live-value', blank: '   ' });
  const env = { MEM_SECRETS_DIR: dir };
  assert.equal(readSecretPresence('openai', env), true);
  assert.equal(readSecretPresence('blank', env), false, 'blank value is absent');
  assert.equal(readSecretPresence('missing', env), false);
  // Presence returns a strict boolean, not a truthy string.
  assert.strictEqual(readSecretPresence('openai', env), true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('readSecretValue returns the trimmed value for a known key (server-side only)', () => {
  const dir = tmpSecrets({ openai: '  sk-trim-me  ' });
  assert.equal(readSecretValue('openai', { MEM_SECRETS_DIR: dir }), 'sk-trim-me');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('fail-closed: absent, corrupt, or non-string store yields null/false and never throws', () => {
  const emptyDir = tmpSecrets(null); // no secrets.json at all
  assert.equal(readSecretValue('openai', { MEM_SECRETS_DIR: emptyDir }), null);
  assert.equal(readSecretPresence('openai', { MEM_SECRETS_DIR: emptyDir }), false);

  const corruptDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-secretstore-'));
  fs.writeFileSync(path.join(corruptDir, 'secrets.json'), '{not json', { mode: 0o600 });
  assert.equal(readSecretValue('openai', { MEM_SECRETS_DIR: corruptDir }), null);
  assert.equal(readSecretPresence('openai', { MEM_SECRETS_DIR: corruptDir }), false);

  const arrDir = tmpSecrets(['not', 'an', 'object']);
  assert.equal(readSecretValue('0', { MEM_SECRETS_DIR: arrDir }), null);

  fs.rmSync(emptyDir, { recursive: true, force: true });
  fs.rmSync(corruptDir, { recursive: true, force: true });
  fs.rmSync(arrDir, { recursive: true, force: true });
});
