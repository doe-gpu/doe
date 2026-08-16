import { createHash } from 'node:crypto';

export function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)];
}

export function summarize(results) {
  const durations = results.map((result) => result.durationMs);
  return {
    cleanProcessRuns: results.length,
    successes: results.filter((result) => result.success).length,
    failures: results.filter((result) => !result.success).length,
    crashes: results.filter((result) => result.crashed).length,
    timeouts: results.filter((result) => result.timedOut).length,
    peakMemoryBytes: Math.max(0, ...results.map((result) => result.peakMemoryBytes)),
    latencyMs: {
      p50: percentile(durations, 0.50),
      p95: percentile(durations, 0.95),
      p99: percentile(durations, 0.99),
    },
  };
}

export function semanticLaneEvidence(lane) {
  return {
    laneId: lane.laneId,
    provider: lane.provider,
    providerModuleSha256: lane.providerModuleSha256,
    probe: {
      identity: lane.probe.identity,
      softwareRenderer: lane.probe.softwareRenderer,
      hardwareEligible: lane.probe.hardwareEligible,
    },
    cases: lane.results.map((result) => ({
      caseId: result.caseId,
      indexSha256: result.indexSha256,
      success: result.success,
      exitCode: result.exitCode,
      signal: result.signal,
      timedOut: result.timedOut,
      crashed: result.crashed,
    })),
  };
}

export function evidenceSha256(value) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}
