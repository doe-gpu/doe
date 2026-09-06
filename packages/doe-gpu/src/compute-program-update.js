// State compatibility and instance-bound approval for prepared-program updates.
import { programError, freezeTree, validateUpdateOptions } from './compute-program-contract.js';
import { lifetime } from './compute-program-residency.js';

const UPDATE_ASSESSMENTS = new WeakMap();

function bufferKey(declaration) {
  return `buffer:${JSON.stringify(declaration)}`;
}

function assessUpdate(current, next, owner, revision) {
  const before = new Map(current.descriptor.buffers.map((buffer) => [buffer.id, buffer]));
  const after = new Map(next.descriptor.buffers.map((buffer) => [buffer.id, buffer]));
  const retained = [];
  const replaced = [];
  const discarded = [];
  const created = [];
  for (const buffer of before.values()) {
    if (lifetime(buffer) !== 'program') continue;
    const replacement = after.get(buffer.id);
    if (!replacement) discarded.push(buffer);
    else if (bufferKey(buffer) === bufferKey(replacement)) retained.push(buffer);
    else replaced.push({ before: buffer, after: replacement });
  }
  for (const buffer of after.values()) {
    if (lifetime(buffer) === 'program' && lifetime(before.get(buffer.id) ?? {}) !== 'program') {
      created.push(buffer);
    }
  }
  const assessment = freezeTree({
    schemaVersion: 1,
    previousProgramHash: current.programHash,
    nextProgramHash: next.programHash,
    revision,
    retained, replaced, discarded, created,
    requiresReset: replaced.length > 0 || discarded.length > 0,
  });
  UPDATE_ASSESSMENTS.set(assessment, { owner, revision, next: JSON.stringify(next.descriptor) });
  return assessment;
}

function authorizeUpdate(current, next, owner, revision, options) {
  const checked = validateUpdateOptions(options);
  let assessment = checked.assessment;
  if (assessment) {
    const authorization = UPDATE_ASSESSMENTS.get(assessment);
    if (!authorization || authorization.owner !== owner || authorization.revision !== revision
        || authorization.next !== JSON.stringify(next.descriptor)) {
      throw programError('DOE_PROGRAM_STALE_ASSESSMENT', 'update.assessment',
        'assessment from this idle program revision for this exact edit', 'stale or foreign assessment');
    }
  } else if (checked.reset === 'approve') {
    throw programError('DOE_PROGRAM_STALE_ASSESSMENT', 'update.assessment',
      'assessment bound to the approved edit', 'missing assessment');
  }
  assessment ??= assessUpdate(current, next, owner, revision);
  const strict = current.descriptor.schemaVersion >= 3 || next.descriptor.schemaVersion >= 3;
  if (strict && assessment.requiresReset && checked.reset !== 'approve') {
    throw Object.assign(programError('DOE_PROGRAM_RESET_REQUIRED', 'update.reset',
      'explicit approval of the assessed state reset', 'state preservation requested'), { assessment });
  }
  return assessment;
}

export { bufferKey, assessUpdate, authorizeUpdate };
