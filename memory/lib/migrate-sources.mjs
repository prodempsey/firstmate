// Conservative migration source enumeration and parsing (PR-3, Milestone A).
//
// This module reads the durable fleet-knowledge corpus a firstmate home already
// holds and turns the ONE arch-sanctioned experience-memory source (learnings.md)
// into proposed CANDIDATE records, while explicitly SURVEYING the remaining
// sources so nothing is silently dropped. It is pure w.r.t. the canonical memory
// registry: it only reads corpus files and returns data. Nothing here ever appends
// a registry event or touches memory-registry.jsonl / memory-index.json / activity.
//
// Conservatism is deliberate and matches the captain-amended architecture
// (memory-arch-amend-m8 §7, memory-arch-plan-m7 §11.1):
//   * Default disposition is `candidate`. Appearing recent or evidence-bearing
//     NEVER makes a record active; migration heuristics cannot manufacture
//     confidence, so every proposed record is `confidence: unverified`.
//   * `[SUPERSEDED ...]` / `DO NOT FOLLOW` markers map to a `superseded`
//     disposition, but the successor link is left to the captain (not guessed).
//   * captain.md, project AGENTS.md, and scout reports are ENUMERATED (counted,
//     listed) but not proposed as records: per arch they are authority/orientation,
//     not experience-memory. Surveying them keeps the corpus review honest without
//     inventing records the arch says do not belong.
//
// Activation is NOT decided here. The tool never auto-nominates records for
// activation; the activation set is the captain's call at dry-run review (§7).

import fs from 'node:fs';
import path from 'node:path';
import { sha256 } from './hash.mjs';

export const MIGRATION_PARSER_VERSION = 'migration-parser/v1';

// The corpus source table. `extract` sources are parsed into candidate records;
// `survey` sources are enumerated and reported but never proposed. Adding a source
// is a data edit here plus (for extract) a parser in PARSERS below.
export const CORPUS_SOURCES = [
  {
    key: 'learnings',
    policy: 'extract',
    kind: 'file',
    rel: 'data/learnings.md',
    label: 'Fleet-local learnings',
    reason: 'dated fleet-local experience-memory entries (arch m7 §11.1: one record each)'
  },
  {
    key: 'captain',
    policy: 'survey',
    kind: 'file',
    rel: 'data/captain.md',
    label: 'Captain preferences and working style',
    reason: 'captain authority/orientation — not experience-memory (arch m7 §11.1: none). Surveyed for corpus completeness, not proposed.'
  },
  {
    key: 'project-agents',
    policy: 'survey',
    kind: 'glob',
    dir: 'projects',
    child: 'AGENTS.md',
    label: 'Project AGENTS.md files',
    reason: 'project-intrinsic authority that travels with each repo — not migrated (arch m7 §11.1: none).'
  },
  {
    key: 'reports',
    policy: 'survey',
    kind: 'glob',
    dir: 'data',
    child: 'report.md',
    label: 'Curated scout report / knowledge files',
    reason: 'scout deliverables / investigation orientation — not experience-memory (arch m7 §11.1: none).'
  }
];

const STOPWORDS = new Set([
  'the', 'and', 'for', 'with', 'this', 'that', 'then', 'than', 'must', 'not', 'now',
  'does', 'into', 'from', 'have', 'has', 'was', 'are', 'its', 'but', 'all', 'any',
  'per', 'via', 'only', 'when', 'what', 'which', 'a', 'an', 'of', 'to', 'in', 'on',
  'is', 'it', 'or', 'be', 'by', 'as', 'at', 'no', 'so', 'up', 'do', 'if'
]);

// A small, curated set of fleet command/bin names worth surfacing as `commands`.
// Deterministic and bounded: migration only extracts what the source text literally
// contains, never an invented vocabulary.
const COMMAND_BINS = new Set([
  'mem', 'tmux', 'git', 'gh-axi', 'krakendesign', 'no-mistakes', 'treehouse',
  'systemctl', 'pgrep', 'pkill', 'kill', 'sed', 'jq'
]);

function slugify(text, max = 60) {
  const slug = String(text)
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return slug.slice(0, max).replace(/-+$/g, '') || 'entry';
}

function truncate(text, max) {
  const t = String(text).trim();
  return t.length <= max ? t : t.slice(0, max);
}

function uniqueSorted(values, cap) {
  const out = [...new Set(values.map((v) => v.trim()).filter(Boolean))].sort();
  return cap ? out.slice(0, cap) : out;
}

// Extract backtick-quoted spans from a body; the source of most concrete anchors
// (commands, file paths). Deterministic, order-preserving before de-dup.
function backtickSpans(body) {
  const spans = [];
  const re = /`([^`]+)`/g;
  let m;
  while ((m = re.exec(body)) !== null) spans.push(m[1].trim());
  return spans;
}

function extractCommands(body) {
  const found = [];
  for (const span of backtickSpans(body)) {
    // A backtick span may be a command line; inspect its first token and any
    // script-file token inside it.
    const tokens = span.split(/[\s(]+/).filter(Boolean);
    for (const raw of tokens) {
      const token = raw.replace(/^[$*]+/, '');
      if (/^[a-z][a-z0-9_-]*\.(?:sh|mjs)$/i.test(token)) found.push(token);
      else if (/^(?:bin\/)?fm-[a-z0-9-]+\.sh$/i.test(token)) found.push(token.replace(/^bin\//, ''));
      else if (COMMAND_BINS.has(token)) found.push(token);
    }
  }
  return uniqueSorted(found, 20);
}

function extractEntities(body) {
  const found = [];
  for (const span of backtickSpans(body)) {
    // File-ish paths with a recognized extension.
    if (/[\w./-]+\.(?:sh|mjs|js|json|md|jsonl|txt)$/i.test(span) && /[\/.]/.test(span)) {
      found.push(span.split(/\s+/)[0]);
    }
  }
  return uniqueSorted(found, 20);
}

function extractEvidence(body) {
  const evidence = [];
  const seen = new Set();
  const push = (type, ref) => {
    const key = `${type}:${ref}`;
    if (!seen.has(key)) {
      seen.add(key);
      evidence.push({ type, ref });
    }
  };
  for (const m of body.matchAll(/\bbug-\d{14}-[0-9a-f]+\b/g)) push('bug', m[0]);
  for (const m of body.matchAll(/\bORD-\d+\b/g)) push('order', m[0]);
  for (const m of body.matchAll(/\bMEM-\d{4,}\b/g)) push('memory', m[0]);
  return evidence.slice(0, 30);
}

function extractKeywords(title) {
  const words = String(title)
    .toLowerCase()
    .replace(/[^a-z0-9\s-]+/g, ' ')
    .split(/[\s-]+/)
    .filter((w) => w.length > 3 && !STOPWORDS.has(w));
  return uniqueSorted(words, 8);
}

// Procedural vs factual is a conservative, signal-based heuristic: a record that
// prescribes an action (a Rule/Fix/Recovery/Going-forward block, or an imperative
// with a concrete command) is procedural; everything else defaults to factual.
function classifyMemoryType(title, body, commands) {
  const proceduralHeader = /\*\*(rule|fix|recovery|going forward|until fixed|when this recurs|procedure|workaround|steps)\b/i;
  if (proceduralHeader.test(body)) return 'procedural';
  if (commands.length > 0 && /\b(do not|never|always|must|before|after)\b/i.test(body)) return 'procedural';
  return 'factual';
}

// Detect an explicit supersession marker. The arch maps `[SUPERSEDED ...]` /
// `DO NOT FOLLOW` to a `superseded` disposition, but the successor is the captain's
// to link — migration does not guess it.
function detectSupersession(title, body) {
  if (/\[superseded\b/i.test(title) || /\[superseded\b/i.test(body) || /do not follow/i.test(body)) {
    return { disposition: 'superseded', reason: 'source carries an explicit [SUPERSEDED]/DO NOT FOLLOW marker; successor link left for the captain' };
  }
  return { disposition: 'candidate', reason: 'potentially useful but unreviewed — default candidate disposition (arch m8 §7)' };
}

// Parse learnings.md into one proposal per `## YYYY-MM-DD — Title` section. The H1
// title and any intro paragraph before the first dated heading are preamble and
// produce no record.
function parseLearnings(text, relPath) {
  const lines = text.split('\n');
  const headingRe = /^##\s+(\d{4}-\d{2}-\d{2})\s*[—–-]\s*(.*)$/;
  const sections = [];
  let current = null;
  lines.forEach((line, idx) => {
    const m = headingRe.exec(line);
    if (m) {
      if (current) sections.push(current);
      current = { date: m[1], title: m[2].trim(), lineStart: idx + 1, bodyLines: [] };
    } else if (current) {
      current.bodyLines.push(line);
    }
  });
  if (current) sections.push(current);

  const anchorCounts = new Map();
  const proposals = [];
  for (const section of sections) {
    const body = section.bodyLines.join('\n').trim();
    const title = section.title || (body.split('\n')[0] || '').trim();
    let anchor = `${section.date}-${slugify(title)}`;
    const seen = anchorCounts.get(anchor) || 0;
    anchorCounts.set(anchor, seen + 1);
    if (seen > 0) anchor = `${anchor}-${seen + 1}`;

    const commands = extractCommands(body);
    const entities = extractEntities(body);
    const evidence = extractEvidence(body);
    const memoryType = classifyMemoryType(title, body, commands);
    const { disposition, reason } = detectSupersession(title, body);
    const lineEnd = section.lineStart + section.bodyLines.length;

    proposals.push({
      memoryType,
      summary: truncate(title, 240),
      body,
      scope: 'fleet',
      projects: ['*'],
      taskKinds: ['*'],
      keywords: extractKeywords(title),
      aliases: [],
      entities,
      commands,
      failureModes: [],
      relatedTerms: [],
      confidence: 'unverified',
      provenance: { source: 'learnings', path: relPath, anchor, lineStart: section.lineStart, lineEnd },
      validFrom: `${section.date}T00:00:00.000Z`,
      evidence,
      disposition,
      dispositionReason: reason,
      supersededBy: null,
      activationNominee: false
    });
  }
  return proposals;
}

const PARSERS = { learnings: parseLearnings };

// Count `## ` headings in a survey file for the enumeration report.
function countSections(text) {
  return (text.match(/^##\s+/gm) || []).length;
}

function firstHeadings(text, cap = 25) {
  const out = [];
  for (const m of text.matchAll(/^##\s+(.+)$/gm)) {
    out.push(m[1].trim());
    if (out.length >= cap) break;
  }
  return out;
}

function resolveFileSource(source, corpusRoot) {
  const abs = path.join(corpusRoot, source.rel);
  const exists = fs.existsSync(abs) && fs.statSync(abs).isFile();
  return { abs, rel: source.rel, exists };
}

// Resolve a `glob` survey source (dir/*/child): enumerate immediate subdirectories
// of `dir` that contain `child`.
function resolveGlobSource(source, corpusRoot) {
  const baseAbs = path.join(corpusRoot, source.dir);
  const matches = [];
  if (fs.existsSync(baseAbs) && fs.statSync(baseAbs).isDirectory()) {
    for (const entry of fs.readdirSync(baseAbs).sort()) {
      const childAbs = path.join(baseAbs, entry, source.child);
      if (fs.existsSync(childAbs) && fs.statSync(childAbs).isFile()) {
        matches.push({ abs: childAbs, rel: path.join(source.dir, entry, source.child) });
      }
    }
  }
  return matches;
}

// Enumerate every corpus source under `corpusRoot`, parse the extract sources into
// proposals, and return { sources, proposals }. `sources` is the full enumeration
// (extract AND survey) so the report proves the whole corpus was considered.
// Proposals carry corpus-RELATIVE provenance paths, so the resulting proposal digest
// is machine-independent (it depends only on content, not on an absolute checkout
// path). Deterministic: sources are processed in table order and proposals in file
// order.
export function enumerateCorpus(corpusRoot) {
  const sources = [];
  const proposals = [];

  for (const source of CORPUS_SOURCES) {
    if (source.kind === 'file') {
      const resolved = resolveFileSource(source, corpusRoot);
      const record = {
        key: source.key,
        policy: source.policy,
        label: source.label,
        reason: source.reason,
        path: resolved.rel,
        exists: resolved.exists,
        itemCount: 0,
        surveyedHeadings: []
      };
      if (resolved.exists) {
        const text = fs.readFileSync(resolved.abs, 'utf8');
        record.sha256 = sha256(text);
        if (source.policy === 'extract') {
          const parser = PARSERS[source.key];
          const parsed = parser(text, resolved.rel);
          record.itemCount = parsed.length;
          proposals.push(...parsed);
        } else {
          record.itemCount = countSections(text);
          record.surveyedHeadings = firstHeadings(text);
        }
      }
      sources.push(record);
    } else if (source.kind === 'glob') {
      const matches = resolveGlobSource(source, corpusRoot);
      const files = [];
      let itemCount = 0;
      for (const match of matches) {
        const text = fs.readFileSync(match.abs, 'utf8');
        const sections = countSections(text);
        itemCount += sections;
        files.push({ path: match.rel, sections, sha256: sha256(text) });
      }
      sources.push({
        key: source.key,
        policy: source.policy,
        label: source.label,
        reason: source.reason,
        path: `${source.dir}/*/${source.child}`,
        exists: files.length > 0,
        fileCount: files.length,
        itemCount,
        files
      });
    }
  }

  return { sources, proposals };
}
