import assert from 'node:assert/strict';
import test from 'node:test';

import { buildRuntimeOwnership } from './runtime-ownership.mjs';

const requiredPlan = {
  claimedProperty: 'independent-correction',
  lanes: Object.fromEntries(
    ['I0', 'I1', 'W0', 'D0', 'P0'].map((laneId) => [
      laneId,
      { requirement: 'required' },
    ]),
  ),
};

function passedRun(laneId) {
  return {
    laneId,
    exitCode: 0,
    timedOut: false,
    result: { oracle: 'pass' },
    providerModulePath: `${laneId}.module`,
  };
}

test('missing ambient and patch controls keep ownership diagnostic', () => {
  const ownership = buildRuntimeOwnership({
    runs: ['I1', 'W0', 'D0'].map(passedRun),
    plan: requiredPlan,
    planSha256: 'a'.repeat(64),
    ambientModuleSupplied: false,
  });

  assert.equal(ownership.status, 'diagnostic-incomplete');
  assert.deepEqual(ownership.missingRequiredLanes, ['I0', 'P0']);
  assert.equal(ownership.lanes.I0.status, 'unavailable');
  assert.equal(ownership.lanes.P0.status, 'not-run');
});

test('all required successful lanes complete the execution matrix', () => {
  const ownership = buildRuntimeOwnership({
    runs: ['I0', 'I1', 'W0', 'D0', 'P0'].map(passedRun),
    plan: requiredPlan,
    planSha256: 'b'.repeat(64),
    ambientModuleSupplied: true,
  });

  assert.equal(ownership.status, 'complete');
  assert.deepEqual(ownership.missingRequiredLanes, []);
});

test('an executed failing lane remains a missing required lane', () => {
  const runs = ['I0', 'I1', 'W0', 'D0', 'P0'].map(passedRun);
  runs.find((run) => run.laneId === 'D0').exitCode = 1;
  const ownership = buildRuntimeOwnership({
    runs,
    plan: requiredPlan,
    planSha256: 'c'.repeat(64),
    ambientModuleSupplied: true,
  });

  assert.equal(ownership.lanes.D0.status, 'failed');
  assert.deepEqual(ownership.missingRequiredLanes, ['D0']);
});
