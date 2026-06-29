/**
 * Immutable interpreter contract for Doe compile inputs.
 *
 * Enforces:
 * - kernel_path and dtype_policy must be declared explicitly; no implicit resolution.
 * - Environment variables must be listed in the declared env block; no silent reads.
 * - The proof loop must be complete before accepting a run as verifiable.
 * - No self-modification: callers must not patch modules or download shaders at
 *   runtime (enforced externally; this module audits the declared input set).
 */

export const PROOF_LOOP_INPUTS = Object.freeze([
  'manifestHash',
  'shardHashes',
  'runtimeVersion',
  'kernelPath',
  'dtypePolicy',
  'inputHash',
]);

/**
 * Throws if kernelPath or dtypePolicy are missing or implicit.
 * Call before invoking any compile or dispatch path.
 */
export function assertExplicitParams(params) {
  const errors = [];
  if (!params.kernelPath || typeof params.kernelPath !== 'string') {
    errors.push('kernelPath must be an explicit non-empty string; implicit resolution is prohibited');
  }
  if (!params.dtypePolicy || typeof params.dtypePolicy !== 'string') {
    errors.push('dtypePolicy must be an explicit non-empty string; implicit precision promotion is prohibited');
  }
  if (errors.length > 0) {
    throw new Error(`immutable interpreter contract violation:\n${errors.join('\n')}`);
  }
}

/**
 * Throws if any key in envRecord is not in declaredEnvKeys.
 * All environment variables consumed during compilation must appear in the
 * receipt's environment block.
 */
export function assertDeclaredEnv(envRecord, declaredEnvKeys) {
  if (!envRecord || typeof envRecord !== 'object') return;
  const declared = new Set(declaredEnvKeys);
  const undeclared = Object.keys(envRecord).filter((k) => !declared.has(k));
  if (undeclared.length > 0) {
    throw new Error(
      `undeclared environment variables in compile inputs: ${undeclared.join(', ')}. ` +
        'All env vars read during compilation must be listed in the receipt environment block.',
    );
  }
}

/**
 * Verifies all six proof-loop inputs are present and non-empty.
 * Returns `{ verified: true, inputs }` or `{ verified: false, reason }`.
 *
 * The proof loop identity:
 *   Manifest + Shards + RuntimeVersion + KernelPath + Dtype + Input => Output
 */
export function verifyProofLoop(inputs) {
  const missing = PROOF_LOOP_INPUTS.filter(
    (k) => inputs[k] === null || inputs[k] === undefined || inputs[k] === '',
  );
  if (missing.length > 0) {
    return {
      verified: false,
      reason: `proof loop inputs incomplete: ${missing.join(', ')}`,
    };
  }
  if (typeof inputs.shardHashes !== 'object' || inputs.shardHashes === null) {
    return {
      verified: false,
      reason: 'proof loop inputs: shardHashes must be a non-null object',
    };
  }
  return { verified: true, inputs: { ...inputs } };
}
