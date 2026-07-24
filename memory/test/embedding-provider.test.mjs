import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  OPENAI_DIM,
  OPENAI_MODEL,
  createOpenAIEmbeddingProvider,
  createStubEmbeddingProvider,
  getEmbeddingProvider,
  hasEmbeddingKey,
  resolveOpenAIApiKey
} from '../lib/embedding-provider.mjs';

function tmpSecrets(obj) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-embed-'));
  if (obj) fs.writeFileSync(path.join(dir, 'secrets.json'), JSON.stringify(obj), { mode: 0o600 });
  return dir;
}

// A stub OpenAI-compatible response.
function okResponse(count, dim) {
  return {
    ok: true,
    status: 200,
    async json() { return { data: Array.from({ length: count }, (_, i) => ({ index: i, embedding: new Array(dim).fill(0.1) })) }; },
    async text() { return ''; }
  };
}

test('resolveOpenAIApiKey precedence: env OPENAI_API_KEY -> MEM_EMBEDDING_KEY -> secret store', () => {
  const dir = tmpSecrets({ openai: 'sk-from-store' });
  assert.equal(resolveOpenAIApiKey({ OPENAI_API_KEY: 'sk-env', MEM_SECRETS_DIR: dir }), 'sk-env');
  assert.equal(resolveOpenAIApiKey({ MEM_EMBEDDING_KEY: 'sk-mem', MEM_SECRETS_DIR: dir }), 'sk-mem');
  assert.equal(resolveOpenAIApiKey({ MEM_SECRETS_DIR: dir }), 'sk-from-store');
  assert.equal(resolveOpenAIApiKey({ MEM_SECRETS_DIR: tmpSecrets(null) }), null, 'no key resolves to null');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('hasEmbeddingKey is presence-only (env or store), never the value', () => {
  const dir = tmpSecrets({ openai: 'sk-secret' });
  assert.equal(hasEmbeddingKey({ OPENAI_API_KEY: 'sk', MEM_SECRETS_DIR: tmpSecrets(null) }), true);
  assert.equal(hasEmbeddingKey({ MEM_SECRETS_DIR: dir }), true);
  assert.equal(hasEmbeddingKey({ MEM_SECRETS_DIR: tmpSecrets(null) }), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('openai provider identity: model text-embedding-3-small @ 1536 dims', () => {
  const p = createOpenAIEmbeddingProvider({ env: { OPENAI_API_KEY: 'sk' } });
  assert.equal(p.model, OPENAI_MODEL);
  assert.equal(p.model, 'text-embedding-3-small');
  assert.equal(p.dimensions, OPENAI_DIM);
  assert.equal(p.dimensions, 1536);
});

test('openai provider embeds via injected fetch and never sends the key anywhere but the auth header', async () => {
  const seen = [];
  const fakeFetch = async (url, init) => {
    seen.push({ url, init });
    const body = JSON.parse(init.body);
    return okResponse(body.input.length, OPENAI_DIM);
  };
  const p = createOpenAIEmbeddingProvider({ env: { OPENAI_API_KEY: 'sk-header-only' }, fetch: fakeFetch });
  const vecs = await p.embedBatch(['a', 'b']);
  assert.equal(vecs.length, 2);
  assert.equal(vecs[0].length, OPENAI_DIM);
  // The model + dimensions are sent; the key rides ONLY in the Authorization header.
  const body = JSON.parse(seen[0].init.body);
  assert.equal(body.model, OPENAI_MODEL);
  assert.equal(body.dimensions, OPENAI_DIM);
  assert.equal(seen[0].init.headers.Authorization, 'Bearer sk-header-only');
  assert.doesNotMatch(init0Body(seen), /sk-header-only/, 'key must not be in the request body');
});

function init0Body(seen) { return seen[0].init.body; }

test('FC-006: an outbound call that hangs past the hard deadline rejects, never blocks forever', async () => {
  // A fetch that never resolves on its own; only the AbortController/deadline ends it.
  const hangingFetch = (url, init) => new Promise((_, reject) => {
    if (init.signal) init.signal.addEventListener('abort', () => reject(new Error('aborted')));
    // no resolve — would hang without the deadline
  });
  const p = createOpenAIEmbeddingProvider({ env: { OPENAI_API_KEY: 'sk' }, fetch: hangingFetch, timeoutMs: 60 });
  const started = process.hrtime.bigint();
  await assert.rejects(() => p.embed('x'), /openai embeddings failed|hard deadline/);
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  assert.ok(elapsedMs < 5000, `deadline bounded the call (${elapsedMs}ms)`);
});

test('batching caps: more than the per-request input cap splits into multiple requests', async () => {
  let requests = 0;
  const fakeFetch = async (url, init) => {
    requests += 1;
    const body = JSON.parse(init.body);
    assert.ok(body.input.length <= 64, 'each request stays within the input-count cap');
    return okResponse(body.input.length, OPENAI_DIM);
  };
  const p = createOpenAIEmbeddingProvider({ env: { OPENAI_API_KEY: 'sk' }, fetch: fakeFetch });
  const out = await p.embedBatch(Array.from({ length: 150 }, (_, i) => `text ${i}`));
  assert.equal(out.length, 150);
  assert.ok(requests >= 3, `150 inputs split across multiple capped requests (${requests})`);
});

test('retriable HTTP status retries then a terminal status throws (no key ever logged)', async () => {
  let n = 0;
  const fakeFetch = async () => {
    n += 1;
    if (n === 1) return { ok: false, status: 429, async json() { return {}; }, async text() { return 'rate limited'; } };
    return { ok: false, status: 400, async json() { return {}; }, async text() { return 'bad request no-key-here'; } };
  };
  const p = createOpenAIEmbeddingProvider({ env: { OPENAI_API_KEY: 'sk-never-logged' }, fetch: fakeFetch, timeoutMs: 2000 });
  await assert.rejects(() => p.embed('x'), (err) => {
    assert.match(err.message, /HTTP 400/);
    assert.doesNotMatch(err.message, /sk-never-logged/, 'key must never appear in a surfaced error');
    return true;
  });
  assert.ok(n >= 2, 'the 429 was retried before the 400 threw');
});

test('missing key throws a clear, keyless error rather than calling out', async () => {
  let called = false;
  const fakeFetch = async () => { called = true; return okResponse(1, OPENAI_DIM); };
  const p = createOpenAIEmbeddingProvider({ env: { MEM_SECRETS_DIR: tmpSecrets(null) }, fetch: fakeFetch });
  assert.equal(await p.canEmbed(), false);
  await assert.rejects(() => p.embed('x'), /no OpenAI API key/);
  assert.equal(called, false, 'no network call is made without a key');
});

test('stub provider is deterministic, offline, and correctly dimensioned', async () => {
  const p = createStubEmbeddingProvider(32);
  assert.equal(p.dimensions, 32);
  const a = await p.embed('hello world');
  const b = await p.embed('hello world');
  assert.deepEqual(a, b, 'same text -> same vector');
  assert.equal(a.length, 32);
  const batch = await p.embedBatch(['x', 'y']);
  assert.equal(batch.length, 2);
});

test('getEmbeddingProvider: default openai, explicit stub, injected provider wins, unknown throws', () => {
  assert.equal(getEmbeddingProvider({ env: {} }).model, OPENAI_MODEL);
  assert.equal(getEmbeddingProvider({ env: { MEM_EMBED_PROVIDER: 'stub' } }).model, 'stub-hash-v1');
  const injected = createStubEmbeddingProvider(8);
  assert.equal(getEmbeddingProvider({ provider: injected, env: { MEM_EMBED_PROVIDER: 'openai' } }), injected);
  assert.throws(() => getEmbeddingProvider({ env: { MEM_EMBED_PROVIDER: 'nope' } }), /unknown MEM_EMBED_PROVIDER/);
});
