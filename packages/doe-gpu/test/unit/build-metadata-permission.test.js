import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, '../..');
const modulePath = resolve(packageRoot, 'src/vendor/webgpu/build-metadata.js');
const fixtureRoot = resolve(here, '../fixtures/build-metadata-permission');
const sidecarPath = resolve(fixtureRoot, 'share/doe-build-metadata.json');
const libraryPath = resolve(fixtureRoot, 'lib/libwebgpu_doe.so');
const packageJsonPath = resolve(packageRoot, 'package.json');

const source = `
  import { loadDoeBuildMetadata } from ${JSON.stringify(pathToFileURL(modulePath).href)};
  const result = loadDoeBuildMetadata({ libraryPath: ${JSON.stringify(libraryPath)} });
  process.stdout.write(JSON.stringify(result));
`;
const child = spawnSync(process.execPath, [
  '--permission',
  `--allow-fs-read=${modulePath}`,
  `--allow-fs-read=${packageJsonPath}`,
  `--allow-fs-read=${sidecarPath}`,
  '--input-type=module',
  '--eval',
  source,
], { encoding: 'utf8' });

assert.equal(child.status, 0, child.stderr);
assert.equal(child.signal, null);
assert.deepEqual(JSON.parse(child.stdout), {
  source: 'workspace',
  path: sidecarPath,
  leanVerifiedBuild: false,
  proofArtifactSha256: null,
});

console.log('build metadata permission contracts: ok');
