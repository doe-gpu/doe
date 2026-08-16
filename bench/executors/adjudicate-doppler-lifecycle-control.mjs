#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../..');
const planPath = resolve(
  repoRoot,
  'bench/vendor-node/doppler_provider_lifecycle_control_qm1.plan.json',
);

function sha256Bytes(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256Bytes(await readFile(path));
}

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

function traceOutputIdentity(trace) {
  return JSON.stringify({
    text: trace?.resultSummary?.generatedTextSha256 ?? null,
    tokens: trace?.resultSummary?.generatedTokenIdsHash ?? null,
  });
}

function inferenceAndReleaseComplete(run) {
  return run.timedOut === false
    && run.trace?.executionSuccessCount === 1
    && run.trace?.resultSummary?.status === 'ok'
    && run.trace?.dopplerSourceTrackedClean === true
    && run.trace?.lifecycleEvidenceState === 'release-complete'
    && run.trace?.providerRelease?.released === true;
}

function postReleaseNativeFailure(run) {
  return inferenceAndReleaseComplete(run)
    && ['abort', 'signal:SIGABRT', 'signal:SIGSEGV'].includes(run.exitCategory);
}

function boundedCleanupComplete(run) {
  const cleanup = run.trace?.providerLifecycleControl;
  return inferenceAndReleaseComplete(run)
    && run.exitCategory === 'zero'
    && cleanup?.supported === true
    && cleanup.awaitedDeviceCount > 0
    && cleanup.destroyedDeviceCount === cleanup.awaitedDeviceCount
    && cleanup.failureCount === 0;
}

async function verifyRawTrace(run) {
  const traceMetaBytes = await readFile(run.traceMetaPath);
  const traceJsonlBytes = await readFile(run.traceJsonlPath);
  const parsedTrace = JSON.parse(traceMetaBytes.toString('utf8'));
  return {
    traceMetaHashMatches: sha256Bytes(traceMetaBytes) === run.traceMetaSha256,
    traceJsonlHashMatches: sha256Bytes(traceJsonlBytes) === run.traceJsonlSha256,
    embeddedTraceMatches: JSON.stringify(parsedTrace) === JSON.stringify(run.trace),
  };
}

function oneStableIdentity(runs) {
  return new Set(runs.map((run) => traceOutputIdentity(run.trace))).size === 1;
}

function uniqueOutputIdentities(runs) {
  return [...new Set(runs.map((run) => traceOutputIdentity(run.trace)))]
    .map((identity) => JSON.parse(identity));
}

export function adjudicate(q0, rawTraceChecks) {
  const wRuns = q0.results?.W0?.runs ?? [];
  const pRuns = q0.results?.P0?.runs ?? [];
  const dRuns = q0.results?.D0?.runs ?? [];
  const allRuns = [...wRuns, ...pRuns, ...dRuns];
  const rawEvidenceValid = rawTraceChecks.length === 9
    && rawTraceChecks.every((check) => Object.values(check).every(Boolean));
  const common = allRuns.length === 9
    && allRuns.every(inferenceAndReleaseComplete)
    && rawEvidenceValid;
  const antecedent = wRuns.length === 3 && wRuns.every(postReleaseNativeFailure);
  const wrapperControl = pRuns.length === 3
    && pRuns.every(boundedCleanupComplete)
    && oneStableIdentity([...wRuns, ...pRuns]);
  const doeControl = dRuns.length === 3
    && dRuns.every((run) => run.exitCategory === 'zero')
    && oneStableIdentity(dRuns);
  const crossProviderOutputIdentity = oneStableIdentity(allRuns);
  const passed = common && antecedent && wrapperControl && doeControl;
  return {
    evidenceValid: common,
    clauses: {
      common,
      antecedent,
      wrapperControl,
      doeControl,
      crossProviderOutputIdentity,
    },
    decision: passed
      ? 'reject-doe-runtime-ownership-wrapper-closes-gap'
      : 'retire-correction-only-readjudication',
    runtimeOwnershipAuthorized: false,
    d0OutputDivergenceRetained: !crossProviderOutputIdentity,
  };
}

async function main() {
  const plan = await readJson(planPath);
  const implementationSha256 = await sha256File(scriptPath);
  if (implementationSha256 !== plan.implementation.sha256) {
    throw new Error(
      `adjudicator hash mismatch: expected ${plan.implementation.sha256}, got ${implementationSha256}`,
    );
  }
  const q0Path = resolve(repoRoot, plan.predecessor.result);
  const q0Sha256 = await sha256File(q0Path);
  if (q0Sha256 !== plan.predecessor.resultSha256) {
    throw new Error(`q0 result hash mismatch: expected ${plan.predecessor.resultSha256}, got ${q0Sha256}`);
  }
  const q0 = await readJson(q0Path);
  const runs = Object.values(q0.results).flatMap((lane) => lane.runs);
  const rawTraceChecks = [];
  for (const run of runs) rawTraceChecks.push(await verifyRawTrace(run));
  const verdict = adjudicate(q0, rawTraceChecks);
  const artifact = {
    schemaVersion: 1,
    artifactKind: 'doe-doppler-provider-lifecycle-control-readjudication',
    generatedAt: new Date().toISOString(),
    plan: { path: planPath, sha256: await sha256File(planPath) },
    implementation: { path: scriptPath, sha256: implementationSha256 },
    predecessor: { path: q0Path, sha256: q0Sha256 },
    rawTraceChecks,
    verdict,
    outputIdentities: {
      W0: uniqueOutputIdentities(q0.results.W0.runs),
      P0: uniqueOutputIdentities(q0.results.P0.runs),
      D0: uniqueOutputIdentities(q0.results.D0.runs),
    },
    terminalPatterns: Object.fromEntries(Object.entries(q0.results).map(([id, lane]) => [
      id,
      lane.runs.map((run) => run.exitCategory),
    ])),
    cleanup: q0.results.P0.runs.map((run) => run.trace.providerLifecycleControl),
    credit: {
      performance: false,
      runtimeOwnership: false,
      promotion: false,
      release: false,
    },
  };
  const resultPath = resolve(dirname(q0Path), 'readjudication-qm1.json');
  await writeFile(resultPath, `${JSON.stringify(artifact, null, 2)}\n`, 'utf8');
  process.stdout.write(`${verdict.decision}\n${resultPath}\n`);
  if (!verdict.evidenceValid) process.exitCode = 1;
}

if (resolve(process.argv[1] ?? '') === scriptPath) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    process.exitCode = 1;
  });
}
