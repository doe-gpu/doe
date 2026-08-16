import assert from 'node:assert/strict';
import test from 'node:test';

import {
  evidenceSha256,
  semanticLaneEvidence,
  summarize,
} from '../external-projects/electronicarts-gigi/suite-evidence.mjs';

function laneResult(durationMs = 4) {
  return {
    laneId: 'W0',
    provider: 'dawn-node-webgpu',
    providerModuleSha256: 'a'.repeat(64),
    probe: {
      identity: { provider: { id: 'dawn-node-webgpu' }, adapter: { vendor: 'AMD' } },
      softwareRenderer: false,
      hardwareEligible: true,
    },
    results: [{
      caseId: 'Textures/Mips',
      indexSha256: 'b'.repeat(64),
      success: true,
      exitCode: 0,
      signal: null,
      timedOut: false,
      crashed: false,
      durationMs,
      peakMemoryBytes: 1024,
      stdout: '',
      stderr: '',
    }],
  };
}

test('semantic replay excludes timing and memory noise', () => {
  const first = laneResult(4);
  const second = laneResult(400);
  second.results[0].peakMemoryBytes = 8192;

  assert.equal(
    evidenceSha256(semanticLaneEvidence(first)),
    evidenceSha256(semanticLaneEvidence(second)),
  );
});

test('semantic replay detects a changed application verdict', () => {
  const first = laneResult();
  const second = laneResult();
  second.results[0].success = false;
  second.results[0].exitCode = 1;

  assert.notEqual(
    evidenceSha256(semanticLaneEvidence(first)),
    evidenceSha256(semanticLaneEvidence(second)),
  );
});

test('suite summary retains correctness, reliability, and latency boundaries', () => {
  const passing = laneResult(10).results[0];
  const failing = {
    ...laneResult(30).results[0],
    success: false,
    exitCode: null,
    signal: 'SIGSEGV',
    crashed: true,
    peakMemoryBytes: 2048,
  };
  const summary = summarize([passing, failing]);

  assert.equal(summary.cleanProcessRuns, 2);
  assert.equal(summary.successes, 1);
  assert.equal(summary.failures, 1);
  assert.equal(summary.crashes, 1);
  assert.equal(summary.timeouts, 0);
  assert.equal(summary.peakMemoryBytes, 2048);
  assert.deepEqual(summary.latencyMs, { p50: 10, p95: 30, p99: 30 });
});
