import { __doeProofProviderIdentity } from 'webgpu';
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

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
