// Timestamp results keep their device units and pass scope explicit.
import { programError } from './compute-program-contract.js';

const QUERY_COUNT = 2;
const QUERY_BYTES = QUERY_COUNT * BigUint64Array.BYTES_PER_ELEMENT;
const EXTERNAL_TIMESTAMP_SOURCES = new WeakMap();

function registerTimestampSource(device, info) {
  EXTERNAL_TIMESTAMP_SOURCES.set(device, Object.freeze({ ...info }));
}

function timestampInfo(device, native, mode) {
  if (mode === 'off') return null;
  const info = native ? native.timestampInfo?.()
    : EXTERNAL_TIMESTAMP_SOURCES.get(device) ?? { periodNs: 1, validBits: 64, source: 'webgpu-nanoseconds' };
  if (!device.features?.has('timestamp-query') || !info
      || (native && info.source !== 'webgpu-nanoseconds')
      || !Number.isFinite(info.periodNs) || info.periodNs <= 0
      || !Number.isInteger(info.validBits) || info.validBits < 1 || info.validBits > 64) {
    throw programError('DOE_PROGRAM_UNSUPPORTED', 'options.gpuTiming',
      'enabled timestamp-query and calibrated provider; rebuild Doe addon/runtime if needed', 'unavailable');
  }
  return Object.freeze({ ...info, source: info.source ?? 'vulkan-query-ticks' });
}

function timestampResult(bytes, offset, info) {
  const [begin, end] = new BigUint64Array(bytes, offset, QUERY_COUNT);
  const ticks = BigInt.asUintN(info.validBits, end - begin);
  const elapsedNs = Number(ticks) * info.periodNs;
  if (ticks > BigInt(Number.MAX_SAFE_INTEGER) || !Number.isFinite(elapsedNs)
      || elapsedNs > Number.MAX_SAFE_INTEGER) {
    throw programError('DOE_PROGRAM_GPU', 'gpuTiming', 'representable elapsed timestamp interval', ticks);
  }
  return { ...info, scope: 'compute-pass', beginTicks: String(begin), endTicks: String(end), elapsedNs };
}

export { QUERY_COUNT, QUERY_BYTES, timestampInfo, timestampResult, registerTimestampSource };
