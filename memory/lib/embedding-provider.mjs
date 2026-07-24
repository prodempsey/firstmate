// The embedding-provider seam for rank-only vectors (Memory PR-2b).
//
// WHY a seam: retrieval reranking (retrieval-vector.mjs) is pure and offline; the
// only place a network/provider key is ever touched is here. One provider is
// implemented — OpenAI `text-embedding-3-small` @ 1536 dims — the same model
// family the cockpit's Neon memory uses (fleet-bridge lib/stores/embeddings.js),
// so a memory built here is dimension-compatible with that store. A deterministic
// offline STUB provider exists for hermetic tests only; it is NOT a product
// fallback (per the captain: no hash-noise vectors in production). When no key is
// available or the provider errors, callers degrade to the still-proven FTS tier
// (see retrieve.mjs) — vectors are OPTIONAL, so their absence NEVER fails a build
// or a recall.
//
// Provider contract:
//   { id, model, dimensions,
//     canEmbed(): Promise<boolean>,          // presence-only; reads no key value into a log
//     embed(text): Promise<number[]>,
//     embedBatch(texts): Promise<number[][]> }
//
// FC-006 (unbounded/synchronous wait on a critical path): every outbound call is
// bounded by a PORTABLE hard deadline. An AbortController aborts the fetch, and an
// OUTER Promise.race wall-clock guard rejects even if the provider ignores the
// abort (SIGKILL-class enforcement: a wedged socket cannot defeat the deadline).
// Batching is capped by input count, per-request chars, and per-input chars so a
// single build can never issue an unbounded request.

import { readSecretPresence, readSecretValue } from './secret-store.mjs';

export const OPENAI_MODEL = 'text-embedding-3-small';
export const OPENAI_DIM = 1536;
const OPENAI_ENDPOINT = 'https://api.openai.com/v1/embeddings';
const OPENAI_MAX_BATCH = 64;             // inputs per request
const OPENAI_MAX_CHARS_PER_REQ = 90000;  // ~22k tokens, under the 300k/request cap
const OPENAI_MAX_INPUT_CHARS = 28000;    // ~7k tokens, under the 8191-token per-input cap
const OPENAI_MAX_RETRIES = 4;
// Per-request hard deadline (ms). Env-overridable so a build in a slow environment
// can raise it, and tests can drop it. A hung request can never exceed this.
export const DEFAULT_EMBED_TIMEOUT_MS = 20000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Deterministic backoff (no Math.random on the critical path; jitter derived from
// the attempt so it stays reproducible and testable).
async function backoff(attempt) {
  const ms = Math.min(8000, 250 * 2 ** attempt) + (attempt * 37) % 200;
  await sleep(ms);
}

// OpenAI rejects empty inputs and enforces a per-input token cap; clamp both.
function sanitizeInput(text) {
  let s = String(text == null ? '' : text);
  if (s.length > OPENAI_MAX_INPUT_CHARS) s = s.slice(0, OPENAI_MAX_INPUT_CHARS);
  return s.trim() ? s : ' ';
}

function timeoutMs(env) {
  const v = Number(env.MEM_EMBED_TIMEOUT_MS);
  return Number.isInteger(v) && v > 0 ? v : DEFAULT_EMBED_TIMEOUT_MS;
}

// Resolve an OpenAI API key WITHOUT throwing and WITHOUT logging the value.
// Precedence: OPENAI_API_KEY -> MEM_EMBEDDING_KEY -> ~/.fleet secret store
// ("openai"). Returns null when none is available (the keyless / FTS-only path).
export function resolveOpenAIApiKey(env = process.env) {
  const envKey = (env.OPENAI_API_KEY || env.MEM_EMBEDDING_KEY || '').trim();
  if (envKey) return envKey;
  const stored = readSecretValue('openai', env);
  return stored || null;
}

// Presence-only check for `mem doctor`. True when a key WOULD resolve, without
// ever reading the key bytes into a return value or a log. Env presence or a
// non-blank secret-store entry both count.
export function hasEmbeddingKey(env = process.env) {
  if ((env.OPENAI_API_KEY || env.MEM_EMBEDDING_KEY || '').trim()) return true;
  return readSecretPresence('openai', env);
}

// Run `fn(signal)` under a portable hard deadline. The AbortController aborts a
// cooperative fetch; the Promise.race rejects regardless so a provider that
// ignores the signal still cannot hold the critical path past the deadline.
async function withHardDeadline(ms, fn) {
  const controller = new AbortController();
  let timer;
  let timedOut = false;
  const deadlineError = () => new Error(`embedding call exceeded ${ms}ms hard deadline`);
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
      reject(deadlineError());
    }, ms);
    // Deliberately NOT unref'd: the deadline must keep the event loop alive until it
    // fires so a hung provider is actively aborted, not silently abandoned when the
    // loop would otherwise drain. clearTimeout in the finally removes it on success.
  });
  // If aborting the fetch makes it reject with its own abort error FIRST, still
  // surface the deadline error so the caller recognizes a bound breach (and does
  // not retry it as a transient network error).
  const work = Promise.resolve(fn(controller.signal)).catch((err) => {
    if (timedOut) throw deadlineError();
    throw err;
  });
  try {
    return await Promise.race([work, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

// OpenAI embeddings provider. Construction is key-free and does NO I/O, so
// selecting it at boot or in an offline test never needs a credential; the key
// resolves lazily on first embed. Call canEmbed() first when the caller wants
// keyless degradation instead of a throw.
export function createOpenAIEmbeddingProvider(opts = {}) {
  const env = opts.env || process.env;
  const dim = OPENAI_DIM;
  // Injectable fetch/deadline for tests (no live API in the suite).
  const doFetch = opts.fetch || globalThis.fetch;
  const hardMs = Number.isInteger(opts.timeoutMs) && opts.timeoutMs > 0 ? opts.timeoutMs : timeoutMs(env);

  async function callBatch(inputs) {
    const key = resolveOpenAIApiKey(env);
    if (!key) throw new Error('no OpenAI API key resolved (env or ~/.fleet secret store)');
    for (let attempt = 0; ; attempt += 1) {
      let res;
      try {
        res = await withHardDeadline(hardMs, (signal) => doFetch(OPENAI_ENDPOINT, {
          method: 'POST',
          signal,
          headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: OPENAI_MODEL, input: inputs, dimensions: dim })
        }));
      } catch (netErr) {
        // A deadline breach is terminal for this attempt-loop: do not keep
        // retrying past the bound on the critical path.
        if (/hard deadline/.test(netErr.message) || attempt >= OPENAI_MAX_RETRIES) {
          throw new Error(`openai embeddings failed: ${netErr.message}`);
        }
        await backoff(attempt + 1);
        continue;
      }
      if (res.ok) {
        const json = await res.json();
        const data = (json.data || []).slice().sort((a, b) => a.index - b.index);
        if (data.length !== inputs.length) {
          throw new Error(`openai returned ${data.length} embeddings for ${inputs.length} inputs`);
        }
        return data.map((d) => d.embedding);
      }
      const retriable = res.status === 429 || res.status >= 500;
      const bodyText = await res.text().catch(() => '');
      if (retriable && attempt < OPENAI_MAX_RETRIES) {
        await backoff(attempt + 1);
        continue;
      }
      // Never include the request body (which carried no key, but stay strict) or
      // any header in the surfaced error; only the status + provider message tail.
      throw new Error(`openai embeddings HTTP ${res.status}: ${bodyText.slice(0, 200)}`);
    }
  }

  async function embedBatch(texts) {
    const prepared = (texts || []).map(sanitizeInput);
    const out = [];
    let batch = [];
    let chars = 0;
    const flush = async () => {
      if (!batch.length) return;
      out.push(...(await callBatch(batch)));
      batch = [];
      chars = 0;
    };
    for (const t of prepared) {
      if (batch.length >= OPENAI_MAX_BATCH || (batch.length && chars + t.length > OPENAI_MAX_CHARS_PER_REQ)) {
        await flush();
      }
      batch.push(t);
      chars += t.length;
    }
    await flush();
    return out;
  }

  return {
    id: `openai:${OPENAI_MODEL}:${dim}`,
    model: OPENAI_MODEL,
    dimensions: dim,
    async canEmbed() { return resolveOpenAIApiKey(env) != null; },
    async embed(text) { const [e] = await embedBatch([text]); return e; },
    embedBatch
  };
}

// ── Deterministic offline STUB (tests only) ──────────────────────────────────
// FNV-1a signed feature-hashing into a fixed-dim, L2-normalized vector. Same text
// -> same vector, no network. NOT a product fallback; select only in tests via
// MEM_EMBED_PROVIDER=stub or by injecting the provider directly.

function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i += 1) {
    h ^= str.charCodeAt(i);
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h >>> 0;
}

function stubEmbed(text, dim) {
  const vec = new Array(dim).fill(0);
  const toks = String(text).toLowerCase().match(/[a-z0-9]{2,}/g) || [];
  const features = [];
  for (let i = 0; i < toks.length; i += 1) {
    features.push(toks[i]);
    if (i + 1 < toks.length) features.push(`${toks[i]}_${toks[i + 1]}`);
  }
  for (const f of features) {
    const idx = fnv1a(f) % dim;
    const sign = (fnv1a(`sign:${f}`) & 1) ? 1 : -1;
    vec[idx] += sign;
  }
  let norm = 0;
  for (const v of vec) norm += v * v;
  norm = Math.sqrt(norm);
  if (norm === 0) { vec[0] = 1; return vec; }
  for (let i = 0; i < dim; i += 1) vec[i] /= norm;
  return vec;
}

export function createStubEmbeddingProvider(dimensions = 64) {
  const dim = Number.isInteger(dimensions) && dimensions > 0 ? dimensions : 64;
  return {
    id: `stub-hash-v1:${dim}`,
    model: 'stub-hash-v1',
    dimensions: dim,
    async canEmbed() { return true; },
    async embed(text) { return stubEmbed(text, dim); },
    async embedBatch(texts) { return (texts || []).map((t) => stubEmbed(t, dim)); }
  };
}

// Select the configured provider. Construction never performs I/O or resolves a
// key, so this is safe at boot and in offline tests. A fully-built provider passed
// as opts.provider always wins (test injection). MEM_EMBED_PROVIDER selects the
// named provider; default is `openai`.
export function getEmbeddingProvider(opts = {}) {
  if (opts.provider && typeof opts.provider.embedBatch === 'function') return opts.provider;
  const env = opts.env || process.env;
  const name = String(env.MEM_EMBED_PROVIDER || 'openai').trim().toLowerCase();
  switch (name) {
    case 'openai':
      return createOpenAIEmbeddingProvider({ env, fetch: opts.fetch, timeoutMs: opts.timeoutMs });
    case 'stub':
      // TEST-ONLY hermetic double. Not a product fallback.
      return createStubEmbeddingProvider(opts.dimensions || Number(env.MEM_EMBED_STUB_DIM) || 64);
    default:
      throw new Error(`unknown MEM_EMBED_PROVIDER "${name}" (known: "openai", "stub")`);
  }
}
