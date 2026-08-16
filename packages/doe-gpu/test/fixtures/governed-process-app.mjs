import { __doeProofProviderIdentity, create } from 'webgpu';
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';

const mode = process.env.DOE_TEST_PROCESS_MODE ?? 'pass';
if (mode === 'hang') {
  setInterval(() => {}, 1_000);
} else if (mode === 'spawn-child' || mode === 'spawn-child-loud') {
  const child = spawn(process.execPath, [
    '-e',
    'setInterval(() => {}, 1000)',
  ], { stdio: 'ignore' });
  writeFileSync(process.env.DOE_TEST_CHILD_PID_PATH, String(child.pid));
  if (mode === 'spawn-child-loud') process.stdout.write('x'.repeat(65_536));
  setInterval(() => {}, 1_000);
} else if (mode === 'loud') {
  process.stdout.write('x'.repeat(65_536));
} else if (mode === 'read-file') {
  const output = JSON.parse(process.env.DOE_TEST_PROCESS_OUTPUT ?? '[]');
  process.stdout.write(`${JSON.stringify({
    providerIdentity: __doeProofProviderIdentity,
    output,
    evidence: {
      artifactKind: 'governed-process-fixture',
      runtimeFile: readFileSync(process.env.DOE_TEST_RUNTIME_FILE, 'utf8'),
    },
  })}\n`);
} else if (mode === 'observed-compute') {
  const gpu = create([]);
  const adapter = await gpu.requestAdapter();
  const device = await adapter.requestDevice();
  const shader = device.createShaderModule({
    code: '@compute @workgroup_size(4) fn main() {}',
  });
  const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: shader, entryPoint: 'main' },
  });
  const buffer = device.createBuffer({ size: 4, usage: 7 });
  device.queue.writeBuffer(buffer, 0, new Uint8Array([2, 4, 6, 8]));
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.dispatchWorkgroups(1);
  pass.end();
  device.queue.submit([encoder.finish()]);
  await device.queue.onSubmittedWorkDone();
  await buffer.mapAsync(1, 0, 4);
  const output = [...new Uint8Array(buffer.getMappedRange(0, 4))];
  device.destroy();
  process.stdout.write(`${JSON.stringify({
    providerIdentity: __doeProofProviderIdentity,
    output,
    evidence: { artifactKind: 'governed-observed-process-fixture' },
  })}\n`);
} else if (mode === 'observed-failure') {
  const gpu = create([]);
  const adapter = await gpu.requestAdapter();
  const device = await adapter.requestDevice();
  const shader = device.createShaderModule({
    code: '@compute @workgroup_size(4) fn main() {}',
  });
  await shader.getCompilationInfo();
  throw new Error('intentional observed fixture failure');
} else {
  const output = JSON.parse(process.env.DOE_TEST_PROCESS_OUTPUT ?? '[]');
  process.stdout.write(`${JSON.stringify({
    providerIdentity: __doeProofProviderIdentity,
    output,
    evidence: {
      artifactKind: 'governed-process-fixture',
      environmentMarker: process.env.DOE_TEST_ENVIRONMENT_MARKER ?? null,
    },
  })}\n`);
}
