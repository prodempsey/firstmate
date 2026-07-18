import crypto from 'node:crypto';

// Lowercase sha256 hex (spec convention: "All hashes are lowercase sha256 over
// canonical JSON"). Node's digest('hex') is already lowercase.
export function sha256(input) {
  return crypto.createHash('sha256').update(input).digest('hex');
}

// Deterministic JSON serialization with sorted object keys, so a hash is stable
// regardless of key insertion order.
export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

export function payloadHash(value) {
  return sha256(canonicalJson(value));
}
