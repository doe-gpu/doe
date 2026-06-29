import { createHash, randomUUID } from 'node:crypto';

export const RECEIPT_VERSION = 'doe.receipt.v1.0';

export const REPLAY_CLASS = Object.freeze({
  BIT_EXACT: 'bit_exact',
  BOUNDED: 'bounded_replay',
});

const REQUIRED_FIELDS = Object.freeze([
  'receipt_version',
  'receipt_id',
  'timestamp_utc',
  'manifest_hash',
  'shard_hashes',
  'runtime_version',
  'kernel_path',
  'dtype_policy',
  'backend',
  'device_descriptor',
  'input_hash',
  'output_hash',
  'replay_class',
  'execution_time_ms',
]);

const REQUIRED_DEVICE_FIELDS = Object.freeze([
  'device_name',
  'driver_version',
  'api_feature_level',
]);

const VALID_BACKENDS = Object.freeze(['WebGPU', 'Vulkan', 'Metal', 'D3D12', 'CSL']);

/**
 * Returns `{ valid: boolean, errors: string[] }`.
 * Downstream consumers (Doppler, Reploid, Columbo) must reject receipts where
 * valid is false.
 */
export function validateReceipt(receipt) {
  if (receipt === null || typeof receipt !== 'object') {
    return { valid: false, errors: ['receipt must be a non-null object'] };
  }

  const errors = [];

  for (const field of REQUIRED_FIELDS) {
    if (!(field in receipt) || receipt[field] === null || receipt[field] === undefined) {
      errors.push(`missing or null required field: ${field}`);
    }
  }

  if (receipt.receipt_version !== RECEIPT_VERSION) {
    errors.push(`receipt_version must be "${RECEIPT_VERSION}", got "${receipt.receipt_version}"`);
  }

  if (!Object.values(REPLAY_CLASS).includes(receipt.replay_class)) {
    errors.push(`replay_class must be one of: ${Object.values(REPLAY_CLASS).join(', ')}`);
  }

  if (!VALID_BACKENDS.includes(receipt.backend)) {
    errors.push(`backend must be one of: ${VALID_BACKENDS.join(', ')}`);
  }

  if (typeof receipt.shard_hashes === 'object' && receipt.shard_hashes !== null) {
    for (const [key, value] of Object.entries(receipt.shard_hashes)) {
      if (!value || typeof value !== 'string') {
        errors.push(`shard_hashes["${key}"]: must be a non-empty string`);
      }
    }
  }

  if (typeof receipt.device_descriptor === 'object' && receipt.device_descriptor !== null) {
    for (const field of REQUIRED_DEVICE_FIELDS) {
      if (!receipt.device_descriptor[field]) {
        errors.push(`device_descriptor.${field}: missing or empty`);
      }
    }
  }

  if (typeof receipt.execution_time_ms === 'number' && receipt.execution_time_ms < 0) {
    errors.push('execution_time_ms must be >= 0');
  }

  return { valid: errors.length === 0, errors };
}

export function computeHash(data) {
  const h = createHash('sha256');
  if (typeof data === 'string') {
    h.update(data, 'utf8');
  } else {
    h.update(data);
  }
  return `sha256:${h.digest('hex')}`;
}

export function buildReceiptId() {
  return `urn:uuid:${randomUUID()}`;
}

/**
 * Classifies replay class from dtype_policy.
 * Integer/fixed-point-only pipelines are bit_exact; any FP path is bounded_replay.
 */
export function classifyReplayClass(dtypePolicy) {
  if (/int|quant|fixed/i.test(dtypePolicy) && !/f16|f32|f64|float/i.test(dtypePolicy)) {
    return REPLAY_CLASS.BIT_EXACT;
  }
  return REPLAY_CLASS.BOUNDED;
}

export function buildReceipt({
  manifestHash,
  shardHashes,
  runtimeVersion,
  kernelPath,
  dtypePolicy,
  backend,
  deviceDescriptor,
  inputHash,
  outputHash,
  executionTimeMs,
  simfabricStall = null,
}) {
  const replayClass = classifyReplayClass(dtypePolicy);
  const receipt = {
    receipt_version: RECEIPT_VERSION,
    receipt_id: buildReceiptId(),
    timestamp_utc: new Date().toISOString(),
    manifest_hash: manifestHash,
    shard_hashes: shardHashes,
    runtime_version: runtimeVersion,
    kernel_path: kernelPath,
    dtype_policy: dtypePolicy,
    backend,
    device_descriptor: deviceDescriptor,
    input_hash: inputHash,
    output_hash: outputHash,
    replay_class: replayClass,
    execution_time_ms: executionTimeMs,
  };
  if (simfabricStall !== null) {
    receipt.simfabric_stall = simfabricStall;
    receipt.replay_class = REPLAY_CLASS.BOUNDED;
  }
  return receipt;
}
