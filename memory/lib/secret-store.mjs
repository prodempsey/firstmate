// Minimal, server-side-only secret reader for the memory package.
//
// This MIRRORS the cockpit's SecretStore file backend (fleet-bridge
// lib/secrets.js + lib/stores/secret-store.file.js) rather than importing it:
// the memory package stays dependency-free of fleet-bridge, but honors the same
// binding contract. Provider keys live in the owner-only 0600 ~/.fleet/secrets.json
// file, OUTSIDE any git repo. The only value this module exposes is through
// readSecretValue(), a SERVER-SIDE-ONLY read for a trusted in-process caller (the
// OpenAI embedding provider). It MUST NEVER be wired into an HTTP route and the
// value MUST NEVER be logged. Presence (readSecretPresence) is the HTTP-safe read.
//
// Fail-closed on every path: a missing/unreadable/corrupt store yields false or
// null, never a throw and never a partial value. The key bytes are never returned
// to any caller other than readSecretValue, and never included in a log line.

import fs from 'node:fs';
import path from 'node:path';

// The secrets file location. Defaults to ~/.fleet/secrets.json (the cockpit's
// path), but is env-overridable so hermetic tests can point at an isolated store
// without touching the operator's real secrets. MEM_SECRETS_PATH wins; otherwise
// MEM_SECRETS_DIR/secrets.json; otherwise $HOME/.fleet/secrets.json.
export function secretsPath(env = process.env) {
  if (env.MEM_SECRETS_PATH) return path.resolve(env.MEM_SECRETS_PATH);
  if (env.MEM_SECRETS_DIR) return path.join(path.resolve(env.MEM_SECRETS_DIR), 'secrets.json');
  const home = env.HOME || process.env.HOME || '';
  return path.join(home, '.fleet', 'secrets.json');
}

// Read the raw store object. Returns {} on any failure (absent file, bad JSON,
// unreadable path) so callers degrade to "no secrets" rather than crashing.
function readStore(env) {
  try {
    const raw = fs.readFileSync(secretsPath(env), 'utf8');
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

// Presence-only: is a non-blank string value stored for `id`? Returns a boolean
// and NEVER the value itself, so this is safe to surface (e.g. in `mem doctor`).
export function readSecretPresence(id, env = process.env) {
  const v = readStore(env)[id];
  return typeof v === 'string' && v.trim().length > 0;
}

// SERVER-SIDE ONLY. Return the trimmed key value for `id`, or null for an
// absent/blank/corrupt entry. Never throws on read; never log the return value.
export function readSecretValue(id, env = process.env) {
  const v = readStore(env)[id];
  return typeof v === 'string' && v.trim() ? v.trim() : null;
}
