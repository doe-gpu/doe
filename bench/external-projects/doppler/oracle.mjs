import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function normalizedDigest(value) {
  return String(value ?? '').replace(/^sha256:/u, '');
}

function providerPathMatches(value, expected) {
  const normalizedValue = String(value ?? '').replaceAll('\\', '/');
  const normalizedExpected = String(expected ?? '').replaceAll('\\', '/');
  return normalizedExpected !== ''
    && (normalizedValue === normalizedExpected || normalizedValue.endsWith(`/${normalizedExpected}`));
}

function scalarIdentityChecks(contract, lane, receipt) {
  const components = receipt?.inputSetComponents ?? {};
  const sampling = receipt?.decodeTranscript?.sampling ?? {};
  const expectedSampling = contract?.execution?.sampling ?? {};
  const tolerance = receipt?.tolerancePolicy ?? {};
  const expectedTolerance = contract?.execution?.tolerance ?? {};
  return [
    {
      id: `${lane}.model`,
      pass: receipt?.modelId === contract?.modelId
        && components.modelId === contract?.modelId,
    },
    {
      id: `${lane}.manifest`,
      pass: normalizedDigest(receipt?.manifestSha256) === normalizedDigest(contract?.manifest?.sha256),
    },
    {
      id: `${lane}.prompt`,
      pass: normalizedDigest(components.promptSha256) === normalizedDigest(contract?.prompt?.sha256),
    },
    {
      id: `${lane}.tokenizer_mode`,
      pass: components.useChatTemplate === contract?.execution?.useChatTemplate
        && Number.isInteger(components.tokenCount)
        && components.tokenCount > 0
        && typeof components.tokenizedPromptSha256 === 'string'
        && components.tokenizedPromptSha256.length === 64,
    },
    {
      id: `${lane}.execution`,
      pass: components.decodeSteps === contract?.execution?.decodeSteps
        && components.runtimeProfile === contract?.execution?.runtimeProfile,
    },
    {
      id: `${lane}.sampling`,
      pass: ['temperature', 'topK', 'topP', 'repetitionPenalty', 'seed']
        .every((key) => sampling[key] === expectedSampling[key]),
    },
    {
      id: `${lane}.tolerance`,
      pass: tolerance.atol === expectedTolerance.atol
        && tolerance.rtol === expectedTolerance.rtol,
    },
    {
      id: `${lane}.provider`,
      pass: providerPathMatches(
        receipt?.producer?.webgpuProvider,
        contract?.providers?.[lane]?.wrapper?.path,
      ),
    },
    {
      id: `${lane}.application`,
      pass: receipt?.producer?.runtime === 'doppler_electron_main_process_webgpu'
        && receipt?.producer?.electronVersion === contract?.application?.version,
    },
  ];
}

export function qualificationIdentity(contract, receipts) {
  const checks = [
    ...scalarIdentityChecks(contract, 'W0', receipts?.W0),
    ...scalarIdentityChecks(contract, 'D0', receipts?.D0),
    {
      id: 'cross_lane.input_set',
      pass: typeof receipts?.W0?.inputSetSha256 === 'string'
        && receipts.W0.inputSetSha256 === receipts?.D0?.inputSetSha256,
    },
    {
      id: 'cross_lane.tokenized_prompt',
      pass: typeof receipts?.W0?.inputSetComponents?.tokenizedPromptSha256 === 'string'
        && receipts.W0.inputSetComponents.tokenizedPromptSha256
          === receipts?.D0?.inputSetComponents?.tokenizedPromptSha256,
    },
    {
      id: 'cross_lane.execution_graph',
      pass: typeof receipts?.W0?.executionGraphSha256 === 'string'
        && receipts.W0.executionGraphSha256 === receipts?.D0?.executionGraphSha256,
    },
    {
      id: 'cross_lane.weight_set',
      pass: typeof receipts?.W0?.weightSetSha256 === 'string'
        && receipts.W0.weightSetSha256 === receipts?.D0?.weightSetSha256,
    },
  ];
  const failed = checks.filter((check) => check.pass !== true).map((check) => check.id);
  return {
    pass: failed.length === 0,
    checkCount: checks.length,
    failed,
    checks,
  };
}

function provesNonzero(digest, byteLength) {
  const size = Number(byteLength);
  return Number.isInteger(size)
    && size > 0
    && normalizedDigest(digest) !== sha256(Buffer.alloc(size));
}

function kvPass(receipt) {
  const evidence = receipt?.kvCacheEvidence;
  return evidence?.status === 'output_ready'
    && evidence?.realKvCache === true
    && Number.isInteger(evidence?.seqLen)
    && evidence.seqLen > 0
    && Array.isArray(evidence?.byteDigests)
    && evidence.byteDigests.some((entry) => (
      provesNonzero(entry?.keyDigest, entry?.keyBytes)
      || provesNonzero(entry?.valueDigest, entry?.valueBytes)
    ));
}

function float32Values(bytes) {
  if (bytes.byteLength % 4 !== 0) {
    throw new Error(`logits artifact byte length ${bytes.byteLength} is not f32-aligned`);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const values = new Float32Array(bytes.byteLength / 4);
  for (let index = 0; index < values.length; index += 1) {
    values[index] = view.getFloat32(index * 4, true);
  }
  return values;
}

async function compareLogits(leftPath, rightPath, tolerance) {
  const [leftBytes, rightBytes] = await Promise.all([
    readFile(leftPath),
    readFile(rightPath),
  ]);
  const left = float32Values(leftBytes);
  const right = float32Values(rightBytes);
  if (left.length !== right.length) {
    return {
      pass: false,
      elementCount: Math.max(left.length, right.length),
      maxAbs: null,
      firstMismatch: 0,
      reason: `shape mismatch: ${left.length} != ${right.length}`,
    };
  }
  let maxAbs = 0;
  let firstMismatch = null;
  for (let index = 0; index < left.length; index += 1) {
    const abs = Math.abs(left[index] - right[index]);
    maxAbs = Math.max(maxAbs, abs);
    const limit = tolerance.atol + tolerance.rtol * Math.abs(left[index]);
    if ((!Number.isFinite(abs) || abs > limit) && firstMismatch === null) {
      firstMismatch = index;
    }
  }
  return {
    pass: firstMismatch === null,
    elementCount: left.length,
    maxAbs,
    firstMismatch,
    reason: firstMismatch === null ? '' : 'abs-or-relative tolerance exceeded',
  };
}

function resolveCheckpointData(record, fileBytes) {
  const artifact = record?.dataArtifact;
  if (
    artifact?.dtype !== 'float32'
    || !Number.isInteger(artifact?.byteOffset)
    || artifact.byteOffset < 0
    || !Number.isInteger(artifact?.byteLength)
    || artifact.byteLength < 0
    || artifact.byteLength % 4 !== 0
    || artifact.byteOffset + artifact.byteLength > fileBytes.byteLength
  ) {
    return null;
  }
  const bytes = fileBytes.subarray(
    artifact.byteOffset,
    artifact.byteOffset + artifact.byteLength,
  );
  if (artifact.sha256 !== sha256(bytes)) {
    return null;
  }
  return {
    view: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    elementCount: bytes.byteLength / 4,
  };
}

function compareCheckpointValues(leftRecord, rightRecord, leftBytes, rightBytes, tolerance) {
  const left = resolveCheckpointData(leftRecord, leftBytes);
  const right = resolveCheckpointData(rightRecord, rightBytes);
  if (!left || !right) {
    return {
      pass: false,
      elementCount: 0,
      maxAbs: null,
      maxRel: null,
      firstMismatch: null,
      reason: 'full checkpoint data is required for tolerance validation',
    };
  }
  if (left.elementCount !== right.elementCount) {
    return {
      pass: false,
      elementCount: Math.max(left.elementCount, right.elementCount),
      maxAbs: null,
      maxRel: null,
      firstMismatch: 0,
      reason: `checkpoint shape mismatch: ${left.elementCount} != ${right.elementCount}`,
    };
  }
  let maxAbs = 0;
  let maxRel = 0;
  let firstMismatch = null;
  for (let index = 0; index < left.elementCount; index += 1) {
    const leftValue = left.view.getFloat32(index * 4, true);
    const rightValue = right.view.getFloat32(index * 4, true);
    const abs = Math.abs(leftValue - rightValue);
    const relativeBase = Math.max(Math.abs(leftValue), Math.abs(rightValue), Number.EPSILON);
    const rel = abs / relativeBase;
    maxAbs = Math.max(maxAbs, abs);
    maxRel = Math.max(maxRel, rel);
    const limit = tolerance.atol + tolerance.rtol * Math.abs(leftValue);
    if (
      (!Number.isFinite(leftValue) || !Number.isFinite(rightValue) || abs > limit)
      && firstMismatch === null
    ) {
      firstMismatch = index;
    }
  }
  return {
    pass: firstMismatch === null,
    elementCount: left.elementCount,
    maxAbs,
    maxRel,
    firstMismatch,
    reason: firstMismatch === null ? '' : 'abs-or-relative tolerance exceeded',
  };
}

function checkpointIdentity(record) {
  return [
    record?.opId ?? null,
    record?.layerIndex ?? null,
    record?.dtype ?? null,
    record?.shapeSignature ?? null,
  ];
}

function compareCheckpointRecords(leftRecords, rightRecords, leftBytes, rightBytes, tolerance) {
  if (!Array.isArray(leftRecords) || !Array.isArray(rightRecords)) {
    return { pass: false, reason: 'checkpoint records are missing', recordCount: 0 };
  }
  if (leftRecords.length !== rightRecords.length) {
    return {
      pass: false,
      reason: `checkpoint record count mismatch: ${leftRecords.length} != ${rightRecords.length}`,
      recordCount: Math.max(leftRecords.length, rightRecords.length),
    };
  }
  let maxAbs = 0;
  let maxRel = 0;
  let elementCount = 0;
  for (let index = 0; index < leftRecords.length; index += 1) {
    const left = leftRecords[index];
    const right = rightRecords[index];
    if (JSON.stringify(checkpointIdentity(left)) !== JSON.stringify(checkpointIdentity(right))) {
      return {
        pass: false,
        reason: `checkpoint identity mismatch at record ${index}`,
        recordCount: leftRecords.length,
        recordIndex: index,
      };
    }
    const numeric = compareCheckpointValues(left, right, leftBytes, rightBytes, tolerance);
    if (!numeric.pass) {
      return {
        ...numeric,
        pass: false,
        reason: `record ${index} (${left?.opId ?? 'unknown'}): ${numeric.reason}`,
        recordCount: leftRecords.length,
        recordIndex: index,
      };
    }
    maxAbs = Math.max(maxAbs, numeric.maxAbs);
    maxRel = Math.max(maxRel, numeric.maxRel);
    elementCount += numeric.elementCount;
  }
  return {
    pass: true,
    reason: '',
    recordCount: leftRecords.length,
    elementCount,
    maxAbs,
    maxRel,
  };
}

function compareKvCheckpoints(left, right) {
  const leftRecords = left?.kv?.records;
  const rightRecords = right?.kv?.records;
  if (!Array.isArray(leftRecords) || !Array.isArray(rightRecords)) {
    return { pass: false, reason: 'KV checkpoint records are missing' };
  }
  if (leftRecords.length !== rightRecords.length) {
    return { pass: false, reason: 'KV checkpoint layer count mismatch' };
  }
  for (let index = 0; index < leftRecords.length; index += 1) {
    const leftRecord = leftRecords[index];
    const rightRecord = rightRecords[index];
    if (
      leftRecord.layerIndex !== rightRecord.layerIndex
      || leftRecord.seqLen !== rightRecord.seqLen
      || leftRecord.keyDigest !== rightRecord.keyDigest
      || leftRecord.valueDigest !== rightRecord.valueDigest
    ) {
      return {
        pass: false,
        reason: `KV checkpoint mismatch at layer record ${index}`,
      };
    }
  }
  return { pass: true, reason: '', layerCount: leftRecords.length };
}

async function compareModelCheckpoints({ contract, laneRoots, receipts }) {
  const [left, right, leftValues, rightValues] = await Promise.all([
    readFile(resolve(laneRoots.W0, 'model_checkpoints.json'), 'utf8').then(JSON.parse),
    readFile(resolve(laneRoots.D0, 'model_checkpoints.json'), 'utf8').then(JSON.parse),
    readFile(resolve(laneRoots.W0, 'model_checkpoint_values.f32')),
    readFile(resolve(laneRoots.D0, 'model_checkpoint_values.f32')),
  ]);
  const requiredStages = contract.execution.checkpointStages.filter((stage) => stage !== 'kv');
  const comparisons = [];
  const blockers = [];
  if (left.status !== 'complete' || right.status !== 'complete') {
    blockers.push('one or both model checkpoint evidence artifacts are incomplete');
  }
  if (
    left.stepCount !== contract.execution.decodeSteps
    || right.stepCount !== contract.execution.decodeSteps
  ) {
    blockers.push('model checkpoint step count does not match the frozen decode count');
  }
  if (left.decodeStepCount < 2 || right.decodeStepCount < 2) {
    blockers.push('model checkpoint evidence contains fewer than two decode steps');
  }
  const stepCount = Math.min(left.steps?.length ?? 0, right.steps?.length ?? 0);
  for (let stepIndex = 0; stepIndex < stepCount; stepIndex += 1) {
    for (const stage of requiredStages) {
      const leftCheckpoint = left.steps[stepIndex]?.checkpoints?.[stage];
      const rightCheckpoint = right.steps[stepIndex]?.checkpoints?.[stage];
      const numeric = compareCheckpointRecords(
        leftCheckpoint?.records,
        rightCheckpoint?.records,
        leftValues,
        rightValues,
        contract.execution.tolerance,
      );
      comparisons.push({
        stepIndex,
        phase: stepIndex === 0 ? 'prefill' : 'decode',
        stage,
        ...numeric,
      });
    }
  }
  const kv = compareKvCheckpoints(left, right);
  if (!kv.pass) blockers.push(kv.reason);
  const receiptPathsPass = receipts.W0?.modelCheckpointEvidence?.status === 'complete'
    && receipts.D0?.modelCheckpointEvidence?.status === 'complete';
  if (!receiptPathsPass) blockers.push('lane receipts do not bind complete checkpoint evidence');
  const expectedComparisonCount = contract.execution.decodeSteps * requiredStages.length;
  return {
    pass: blockers.length === 0
      && comparisons.length === expectedComparisonCount
      && comparisons.every((entry) => entry.pass),
    expectedComparisonCount,
    comparisons,
    kv,
    blockers,
  };
}

function capturedStages(receipt) {
  const stages = new Set(
    Array.isArray(receipt?.checkpointDigests)
      ? receipt.checkpointDigests.map((entry) => entry?.stage).filter(Boolean)
      : [],
  );
  if (receipt?.tensorDigest?.status === 'output_ready') stages.add('logits');
  if (kvPass(receipt)) stages.add('kv');
  return stages;
}

export async function evaluateQualification({ contract, laneRoots, receipts }) {
  const identity = qualificationIdentity(contract, receipts);
  const requestedSteps = contract.execution.decodeSteps;
  const w0Steps = receipts.W0?.decodeTranscript?.logitsDigests ?? [];
  const d0Steps = receipts.D0?.decodeTranscript?.logitsDigests ?? [];
  const stepCountPass = receipts.W0?.decodeTranscript?.actualDecodeSteps === requestedSteps
    && receipts.D0?.decodeTranscript?.actualDecodeSteps === requestedSteps
    && w0Steps.length === requestedSteps
    && d0Steps.length === requestedSteps;
  const comparisons = [];
  if (stepCountPass) {
    for (let index = 0; index < requestedSteps; index += 1) {
      const left = w0Steps[index];
      const right = d0Steps[index];
      const numeric = await compareLogits(
        resolve(laneRoots.W0, `logits_step_${String(index).padStart(3, '0')}.f32`)
          .replace(/logits_step_000\.f32$/u, 'final_logits.f32'),
        resolve(laneRoots.D0, `logits_step_${String(index).padStart(3, '0')}.f32`)
          .replace(/logits_step_000\.f32$/u, 'final_logits.f32'),
        contract.execution.tolerance,
      );
      comparisons.push({
        stepIndex: index,
        selectedTokenIdW0: left.selectedTokenId,
        selectedTokenIdD0: right.selectedTokenId,
        tokenPass: left.selectedTokenId === right.selectedTokenId,
        ...numeric,
        pass: numeric.pass && left.selectedTokenId === right.selectedTokenId,
      });
    }
  }
  const requiredStages = contract.execution.checkpointStages;
  const checkpointCoverage = Object.fromEntries(
    ['W0', 'D0'].map((lane) => {
      const captured = capturedStages(receipts[lane]);
      const missing = requiredStages.filter((stage) => !captured.has(stage));
      return [lane, {
        pass: missing.length === 0,
        captured: [...captured].sort(),
        missing,
      }];
    }),
  );
  const kv = { W0: kvPass(receipts.W0), D0: kvPass(receipts.D0) };
  const modelCheckpoints = await compareModelCheckpoints({ contract, laneRoots, receipts });
  const pass = identity.pass
    && stepCountPass
    && comparisons.length === requestedSteps
    && comparisons.every((entry) => entry.pass)
    && kv.W0
    && kv.D0
    && checkpointCoverage.W0.pass
    && checkpointCoverage.D0.pass
    && modelCheckpoints.pass;
  return {
    schemaVersion: 1,
    artifactKind: 'doe-gemma270m-electron-oracle-result',
    status: pass ? 'passed' : 'failed',
    modelId: contract.modelId,
    identity,
    requestedDecodeSteps: requestedSteps,
    stepCountPass,
    logitsComparisons: comparisons,
    kv,
    checkpointCoverage,
    modelCheckpoints,
    pass,
  };
}
