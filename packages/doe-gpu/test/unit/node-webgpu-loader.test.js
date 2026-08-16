import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const loader = new URL('../../src/node-webgpu-loader.js', import.meta.url);
const application = new URL('../fixtures/provider-loader-app.mjs', import.meta.url);
const provider = new URL('../fixtures/provider-v1.js', import.meta.url);

function run(environment) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [
      '--no-warnings',
      '--experimental-loader',
      fileURLToPath(loader),
      fileURLToPath(application),
    ], {
      env: { ...process.env, ...environment },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('close', (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

const success = await run({
  DOE_NODE_WEBGPU_PROVIDER_ID: 'fixture-provider',
  DOE_NODE_WEBGPU_PROVIDER_MODULE: provider.href,
});
assert.equal(success.code, 0, success.stderr);
const result = JSON.parse(success.stdout);
assert.equal(result.identity.contract, 'doe.node-webgpu-loader/v1');
assert.equal(result.identity.providerId, 'fixture-provider');
assert.equal(result.identity.providerModule, provider.href);
assert.equal(result.identity.resolvedProviderUrl, provider.href);
assert.deepEqual(result.runtimeInfo, { provider: 'fixture-provider', initialized: true });
assert.equal(result.providerInfoCalls, 1);
assert.equal(result.hasCreate, true);
assert.equal(result.hasGlobals, true);
assert.equal(result.adapterLabel, 'provider-v1-test-adapter');

const missing = await run({
  DOE_NODE_WEBGPU_PROVIDER_ID: '',
  DOE_NODE_WEBGPU_PROVIDER_MODULE: '',
});
assert.notEqual(missing.code, 0);
assert.match(missing.stderr, /DOE_NODE_WEBGPU_PROVIDER_ID must be an explicit provider identifier/);

const observationWithoutGovernedIpc = await run({
  DOE_NODE_WEBGPU_PROVIDER_ID: 'fixture-provider',
  DOE_NODE_WEBGPU_PROVIDER_MODULE: provider.href,
  DOE_NODE_WEBGPU_OBSERVE_PROGRAM: '1',
  DOE_NODE_WEBGPU_OBSERVE_METADATA: JSON.stringify({ contract: 'loader-unit' }),
});
assert.notEqual(observationWithoutGovernedIpc.code, 0);
assert.match(observationWithoutGovernedIpc.stderr, /governed process IPC contract/);

const invalidObservationMode = await run({
  DOE_NODE_WEBGPU_PROVIDER_ID: 'fixture-provider',
  DOE_NODE_WEBGPU_PROVIDER_MODULE: provider.href,
  DOE_NODE_WEBGPU_OBSERVE_PROGRAM: 'yes',
});
assert.notEqual(invalidObservationMode.code, 0);
assert.match(invalidObservationMode.stderr, /must be 0 or 1/);

console.log('node-webgpu loader contracts: ok');
