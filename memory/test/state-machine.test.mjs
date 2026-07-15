import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { appendRegistryEvent, buildActiveIndex, foldRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { tmpRegistry } from './helpers.mjs';

const firstmate = { kind: 'firstmate', id: 'fm' };
const captain = { kind: 'captain', id: 'captain' };

async function propose(dir, memId, fields = {}, extra = {}) {
  return appendRegistryEvent(dir, { event: 'proposed', memId, actor: firstmate, fields: { summary: `${memId} summary`, ...fields }, ...extra });
}
async function activate(dir, memId, actor = captain, extra = {}) {
  return appendRegistryEvent(dir, { event: 'activated', memId, actor, evidence: [{ type: 'test', ref: memId }], validation: { method: 'test', by: actor.id || 'validator', ref: `auth-${memId}` }, ...extra });
}

// Reject an event AND prove the canonical registry bytes did not change.
async function assertRejectsNoChange(dir, partial, pattern) {
  const reg = registryPaths(dir).registry;
  const before = fs.existsSync(reg) ? fs.readFileSync(reg) : Buffer.alloc(0);
  await assert.rejects(appendRegistryEvent(dir, partial), pattern);
  const after = fs.existsSync(reg) ? fs.readFileSync(reg) : Buffer.alloc(0);
  assert.equal(after.equals(before), true, 'rejected mutation must leave canonical registry bytes unchanged');
}

// ---- Finding 2: guard_linked canonical normalization + conflict rejection ----

test('finding-2: top-level guard_linked is normalized before activation governance and cannot bypass it', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, fields: { summary: 'ordinary until activation guard' } });
  await assertRejectsNoChange(dir, {
    event: 'activated', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' },
    guard_linked: true,
    evidence: [{ type: 'test', ref: 'top-level-guard' }],
    validation: { method: 'qa', by: 'same-agent', ref: 'qa-ref' }
  }, /high-impact activation requires an independent activator or captain authority/);
  const rec = foldRegistry(dir).records.get('MEM-0001');
  assert.equal(rec.status, 'candidate');
  assert.equal(rec.guardLinked, false);
});

test('finding-2: top-level and nested guard_linked have the same activation outcome', async () => {
  for (const [label, guard] of [['top-level', { guard_linked: true }], ['nested', { fields: { summary: 'nested guard', guard_linked: true } }]]) {
    const dir = tmpRegistry();
    await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, fields: { summary: `${label} guard candidate` } });
    await assertRejectsNoChange(dir, {
      event: 'activated', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, ...guard,
      evidence: [{ type: 'test', ref: label }], validation: { method: 'qa', by: 'same-agent', ref: 'qa-ref' }
    }, /high-impact activation requires an independent activator or captain authority/);
  }
});

test('finding-2: conflicting top-level vs nested guard_linked fails closed before append', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'a' }, fields: { summary: 'conflict candidate' } });
  await assertRejectsNoChange(dir, {
    event: 'activated', memId: 'MEM-0001', actor: captain,
    guard_linked: true, fields: { guard_linked: false },
    evidence: [{ type: 'test', ref: 'conflict' }], validation: { method: 'qa', by: 'captain', ref: 'auth' }
  }, /conflicting guard_linked representations/);
});

test('finding-2: proposal guard linkage survives a sparse update that omits it', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'proposer' }, guard_linked: true, fields: { summary: 'guarded memory' } });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').guardLinked, true);
  await appendRegistryEvent(dir, { event: 'updated', memId: 'MEM-0001', actor: firstmate, fields: { summary: 'guarded memory (edited)' } });
  const rec = foldRegistry(dir).records.get('MEM-0001');
  assert.equal(rec.guardLinked, true, 'sparse update must preserve guard linkage');
  assert.equal(rec.summary, 'guarded memory (edited)');
});

test('finding-2: a guard-linked candidate cannot self-activate but captain authority succeeds', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, guard_linked: true, fields: { summary: 'guarded self-activation' } });
  await assertRejectsNoChange(dir, {
    event: 'activated', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' },
    evidence: [{ type: 'test', ref: 'self' }], validation: { method: 'qa', by: 'same-agent', ref: 'qa-ref' }
  }, /independent activator or captain authority/);
  await appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 'ok' }], validation: { method: 'qa', by: 'captain', ref: 'auth-cap' } });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

// ---- Finding 3: canonical top-level supersedes validation + lineage mutation ----

test('finding-3: top-level supersedes runs the canonical validator before any mutation', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001'); await activate(dir, 'MEM-0001');
  await propose(dir, 'MEM-0002'); await activate(dir, 'MEM-0002');

  // Dangling target -> refused, no mutation.
  await assertRejectsNoChange(dir, {
    event: 'updated', memId: 'MEM-0002', actor: firstmate,
    evidence: [{ type: 'test', ref: 'dangling' }], supersedes: ['MEM-9999']
  }, /supersession target not found: MEM-9999/);

  // Self-reference -> refused, no mutation.
  await assertRejectsNoChange(dir, {
    event: 'updated', memId: 'MEM-0002', actor: firstmate,
    evidence: [{ type: 'test', ref: 'self' }], supersedes: ['MEM-0002']
  }, /cannot supersede itself/);

  // Valid top-level supersession consistently updates both sides.
  await appendRegistryEvent(dir, {
    event: 'updated', memId: 'MEM-0002', actor: firstmate,
    evidence: [{ type: 'test', ref: 'valid' }], supersedes: ['MEM-0001']
  });
  const fold = foldRegistry(dir);
  assert.equal(fold.records.get('MEM-0001').status, 'superseded');
  assert.equal(fold.records.get('MEM-0001').supersededBy, 'MEM-0002');
  assert.ok(fold.records.get('MEM-0002').supersedes.includes('MEM-0001'));
});

test('finding-3: top-level supersedes enforces target-state and active-successor rules', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001'); await activate(dir, 'MEM-0001');
  await propose(dir, 'MEM-0002'); await activate(dir, 'MEM-0002');
  await appendRegistryEvent(dir, { event: 'retired', memId: 'MEM-0002', actor: firstmate });
  // Terminal (retired) target cannot be superseded.
  await assertRejectsNoChange(dir, {
    event: 'updated', memId: 'MEM-0001', actor: firstmate,
    evidence: [{ type: 'test', ref: 'terminal-target' }], supersedes: ['MEM-0002']
  }, /supersession target must be active or candidate/);

  // The successor (event.memId) must itself be active.
  await propose(dir, 'MEM-0003'); await activate(dir, 'MEM-0003');
  await propose(dir, 'MEM-0004'); await activate(dir, 'MEM-0004');
  await appendRegistryEvent(dir, { event: 'quarantined', memId: 'MEM-0003', actor: firstmate });
  await assertRejectsNoChange(dir, {
    event: 'updated', memId: 'MEM-0003', actor: firstmate,
    evidence: [{ type: 'test', ref: 'inactive-successor' }], supersedes: ['MEM-0004']
  }, /supersession successor must be active/);
});

test('finding-3: top-level supersedes refuses self and reverse (A->B then B->A) lineage without mutation', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001'); await activate(dir, 'MEM-0001');
  await propose(dir, 'MEM-0002'); await activate(dir, 'MEM-0002');
  // MEM-0002 supersedes MEM-0001.
  await appendRegistryEvent(dir, { event: 'updated', memId: 'MEM-0002', actor: firstmate, evidence: [{ type: 'test', ref: 'fwd' }], supersedes: ['MEM-0001'] });
  const before = foldRegistry(dir).watermark.seq;
  // MEM-0001 is now superseded (terminal); it cannot turn around and supersede
  // MEM-0002. The terminal-state transition guard refuses the reverse event
  // before supersession logic, so the lineage can never cycle back.
  await assertRejectsNoChange(dir, {
    event: 'updated', memId: 'MEM-0001', actor: firstmate,
    evidence: [{ type: 'test', ref: 'rev' }], supersedes: ['MEM-0002']
  }, /illegal transition: superseded --updated-->/);
  const fold = foldRegistry(dir);
  assert.equal(fold.watermark.seq, before);
  assert.equal(fold.records.get('MEM-0002').status, 'active');
  assert.deepEqual(fold.records.get('MEM-0002').supersedes, ['MEM-0001']);
});

test('finding-3: top-level supersedes and the superseded event yield identical canonical lineage', async () => {
  const build = async (useTopLevel) => {
    const dir = tmpRegistry();
    await propose(dir, 'MEM-0001'); await activate(dir, 'MEM-0001');
    await propose(dir, 'MEM-0002'); await activate(dir, 'MEM-0002');
    if (useTopLevel) {
      await appendRegistryEvent(dir, { event: 'updated', memId: 'MEM-0002', actor: firstmate, evidence: [{ type: 'test', ref: 't' }], supersedes: ['MEM-0001'] });
    } else {
      await appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-0002', actor: firstmate });
    }
    const f = foldRegistry(dir);
    return { status: f.records.get('MEM-0001').status, by: f.records.get('MEM-0001').supersededBy, sup: f.records.get('MEM-0002').supersedes };
  };
  const viaTopLevel = await build(true);
  const viaEvent = await build(false);
  assert.equal(viaTopLevel.status, 'superseded');
  assert.equal(viaTopLevel.by, 'MEM-0002');
  assert.deepEqual(viaTopLevel.sup, ['MEM-0001']);
  assert.deepEqual(viaTopLevel, viaEvent, 'both supersession representations must produce identical lineage');
});

test('m7-17 independent high-impact activation requires concrete independent actor IDs', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, fields: { summary: 'dispatch guidance', taskKinds: ['dispatch'] } });
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: { kind: 'agent' }, evidence: [{ type: 'test', ref: 'missing-activator' }], validation: { method: 'qa', by: 'qa', ref: 'qa-ref' } }),
    /requires activator actor\.id/
  );
  // Same actor, high-impact task kind, no captain authority -> refused.
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, evidence: [{ type: 'test', ref: 'self' }], validation: { method: 'qa', by: 'qa', ref: 'qa-ref' } }),
    /high-impact activation requires an independent activator or captain authority/
  );
  // An independent activator succeeds.
  await activate(dir, 'MEM-0001', { kind: 'agent', id: 'other-agent' });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('activation fields cannot erase high-impact governance before authorization', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, {
    event: 'proposed',
    memId: 'MEM-0001',
    actor: { kind: 'agent', id: 'same-agent' },
    fields: {
      summary: 'critical dispatch governance',
      riskClass: 'critical',
      taskKinds: ['dispatch'],
      guard_linked: true
    }
  });

  await assert.rejects(
    appendRegistryEvent(dir, {
      event: 'activated',
      memId: 'MEM-0001',
      actor: { kind: 'agent', id: 'same-agent' },
      fields: {
        riskClass: 'standard',
        taskKinds: [],
        guard_linked: false
      },
      evidence: [{ type: 'test', ref: 'self-downgrade' }],
      validation: { method: 'qa', by: 'same-agent', ref: 'qa-ref' }
    }),
    /high-impact activation requires an independent activator or captain authority/
  );

  const record = foldRegistry(dir).records.get('MEM-0001');
  assert.equal(record.status, 'candidate');
  assert.equal(record.riskClass, 'critical');
  assert.deepEqual(record.taskKinds, ['dispatch']);
  assert.equal(record.guardLinked, true);
  assert.deepEqual(buildActiveIndex(dir).records, []);
});

test('high-impact proposal requires proposer ID and Captain authority requires an authorization reference', async () => {
  const dir = tmpRegistry();
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent' }, fields: { summary: 'anonymous governance', taskKinds: ['governance'] } }),
    /high-impact proposal requires actor\.id/
  );
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: captain, fields: { summary: 'governance rule', taskKinds: ['governance'] } });
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 'cap' }], validation: { method: 'test', by: 'captain' } }),
    /authorization reference/
  );
  await activate(dir, 'MEM-0001', captain);
  assert.equal(foldRegistry(dir).records.get('MEM-0001').activatedBy.authorizationRef, 'auth-MEM-0001');
});

test('two missing actor IDs are not independent for high-impact activation', async () => {
  const dir = tmpRegistry();
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent' }, fields: { summary: 'dispatch anonymous', taskKinds: ['dispatch'] } }),
    /high-impact proposal requires actor\.id/
  );
});

test('captain authority may activate high-impact memory even as the proposer with authorization', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: captain, fields: { summary: 'governance rule', taskKinds: ['governance'] } });
  await activate(dir, 'MEM-0001', captain);
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('non-high-impact memory may be activated by its proposer', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'a' }, fields: { summary: 'ordinary note' } });
  await activate(dir, 'MEM-0001', { kind: 'agent', id: 'a' });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('quarantined -> active only via revalidate with evidence, never via ordinary activate', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await activate(dir, 'MEM-0001');
  await appendRegistryEvent(dir, { event: 'quarantined', memId: 'MEM-0001', actor: firstmate, reason: 'suspect' });
  await assert.rejects(activate(dir, 'MEM-0001'), /illegal transition: quarantined --activated/);
  // revalidate requires evidence + validation
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'revalidated', memId: 'MEM-0001', actor: captain, validation: { method: 'test' } }),
    /requires.*evidence/i
  );
  await appendRegistryEvent(dir, { event: 'revalidated', memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 're' }], validation: { method: 'test' } });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('supersession requires an existing active successor and is non-dangling', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await activate(dir, 'MEM-0001');
  // No successor supplied -> refused at schema level.
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', actor: firstmate }),
    /superseded event requires a successor/
  );
  // Successor does not exist -> refused.
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-9999', actor: firstmate }),
    /successor not found/
  );
  // Successor exists but is only a candidate -> refused.
  await propose(dir, 'MEM-0002');
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-0002', actor: firstmate }),
    /successor must be active/
  );
  // Valid supersession updates both sides.
  await activate(dir, 'MEM-0002');
  await appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-0002', actor: firstmate });
  const fold = foldRegistry(dir);
  assert.equal(fold.records.get('MEM-0001').status, 'superseded');
  assert.equal(fold.records.get('MEM-0001').supersededBy, 'MEM-0002');
  assert.ok(fold.records.get('MEM-0002').supersedes.includes('MEM-0001'));
});

test('supersession refuses self-cycles and A-to-B then B-to-A cycles without mutating state', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await activate(dir, 'MEM-0001');
  const beforeSelf = foldRegistry(dir).watermark.seq;
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-0001', actor: firstmate }),
    /cannot supersede itself/
  );
  assert.equal(foldRegistry(dir).watermark.seq, beforeSelf);

  await propose(dir, 'MEM-0002');
  await activate(dir, 'MEM-0002');
  await appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-0002', actor: firstmate });
  const beforeCycle = foldRegistry(dir).watermark.seq;
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0002', successor: 'MEM-0001', actor: firstmate }),
    /successor must be active/
  );
  const fold = foldRegistry(dir);
  assert.equal(fold.watermark.seq, beforeCycle);
  assert.equal(fold.records.get('MEM-0002').status, 'active');
  assert.deepEqual(fold.records.get('MEM-0002').supersedes, ['MEM-0001']);
});

test('candidate cannot self-activate without validation evidence', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: firstmate, validation: { method: 'test' } }),
    /requires.*evidence/i
  );
});

test('terminal states are terminal: no ordinary transition revives them, canonical state unchanged', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await activate(dir, 'MEM-0001');
  await appendRegistryEvent(dir, { event: 'retired', memId: 'MEM-0001', actor: firstmate, reason: 'done' });

  const seqBefore = foldRegistry(dir).watermark.seq;
  for (const event of ['activated', 'updated', 'quarantined', 'revalidated']) {
    await assert.rejects(
      appendRegistryEvent(dir, { event, memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 'x' }], validation: { method: 'test' }, fields: { summary: 'noop' } }),
      /illegal transition|requires/
    );
  }
  const foldAfter = foldRegistry(dir);
  assert.equal(foldAfter.watermark.seq, seqBefore, 'illegal transitions must not alter canonical state');
  assert.equal(foldAfter.records.get('MEM-0001').status, 'retired');
});

test('every illegal (status, event) edge is refused', async () => {
  // candidate cannot be revalidated (only quarantined can); rejected is terminal.
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'revalidated', memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 'x' }], validation: { method: 'test' } }),
    /illegal transition: candidate --revalidated/
  );
  await appendRegistryEvent(dir, { event: 'rejected', memId: 'MEM-0001', actor: firstmate, reason: 'no' });
  await assert.rejects(activate(dir, 'MEM-0001'), /illegal transition: rejected --activated/);
});
