import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const runtime = await import('../../src/index.js');
const declarationSource = await readFile(
  new URL('../../src/index.d.ts', import.meta.url),
  'utf8',
);

const declaredValues = new Set();
for (const match of declarationSource.matchAll(
  /^export\s+(?:declare\s+)?(?:const|let|var|function|class|enum)\s+([A-Za-z_$][A-Za-z0-9_$]*)/gm,
)) {
  declaredValues.add(match[1]);
}
for (const match of declarationSource.matchAll(
  /^export\s*\{\s*([A-Za-z_$][A-Za-z0-9_$]*)\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\};/gm,
)) {
  declaredValues.add(match[2]);
}
if (/^export\s+default\s+/m.test(declarationSource)) {
  declaredValues.add('default');
}

const runtimeValues = new Set(Object.keys(runtime));
assert.deepEqual(
  [...runtimeValues].sort(),
  [...declaredValues].sort(),
  'root JavaScript exports must exactly match root declaration value exports',
);
assert.ok(runtimeValues.has('requestRawDevice'));
assert.ok(runtimeValues.has('requestBoundDevice'));

console.log('root runtime/declaration export parity: ok');
