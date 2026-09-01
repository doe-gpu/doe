import assert from 'node:assert/strict';
import test from 'node:test';

import { qualificationIdentity } from '../external-projects/doppler/oracle.mjs';

const contract = {
  modelId: 'gemma-3-270m-it-q4k-ehf16-af32',
  manifest: { sha256: 'a'.repeat(64) },
  prompt: { sha256: 'b'.repeat(64) },
  application: { version: '43.4.0' },
  execution: {
    decodeSteps: 4,
    runtimeProfile: 'profiles/production',
    useChatTemplate: false,
    sampling: {
      temperature: 0,
      topK: 1,
      topP: 1,
      repetitionPenalty: 1,
      seed: 0,
    },
    tolerance: { atol: 0.001, rtol: 0 },
  },
  providers: {
    W0: { wrapper: { path: 'bench/external-projects/doppler/provider-dawn.mjs' } },
    D0: { wrapper: { path: 'bench/external-projects/doppler/provider-doe.mjs' } },
  },
};

function receipt(lane) {
  const wrapper = contract.providers[lane].wrapper.path;
  return {
    modelId: contract.modelId,
    manifestSha256: contract.manifest.sha256,
    inputSetSha256: 'c'.repeat(64),
    executionGraphSha256: 'd'.repeat(64),
    weightSetSha256: 'e'.repeat(64),
    inputSetComponents: {
      modelId: contract.modelId,
      promptSha256: contract.prompt.sha256,
      useChatTemplate: false,
      tokenCount: 11,
      tokenizedPromptSha256: 'f'.repeat(64),
      decodeSteps: 4,
      runtimeProfile: 'profiles/production',
    },
    decodeTranscript: { sampling: { ...contract.execution.sampling } },
    tolerancePolicy: { atol: 0.001, rtol: 0 },
    producer: {
      runtime: 'doppler_electron_main_process_webgpu',
      electronVersion: '43.4.0',
      webgpuProvider: `/home/x/deco/doe/${wrapper}`,
    },
  };
}

test('qualification identity accepts the complete frozen W0/D0 contract', () => {
  const result = qualificationIdentity(contract, {
    W0: receipt('W0'),
    D0: receipt('D0'),
  });
  assert.equal(result.pass, true);
  assert.deepEqual(result.failed, []);
});

test('qualification identity rejects a mutually matching chat-template transcript', () => {
  const w0 = receipt('W0');
  const d0 = receipt('D0');
  w0.inputSetComponents.useChatTemplate = true;
  d0.inputSetComponents.useChatTemplate = true;
  const result = qualificationIdentity(contract, { W0: w0, D0: d0 });
  assert.equal(result.pass, false);
  assert.deepEqual(result.failed, ['W0.tokenizer_mode', 'D0.tokenizer_mode']);
});

test('qualification identity rejects a provider that bypasses its wrapper', () => {
  const w0 = receipt('W0');
  const d0 = receipt('D0');
  d0.producer.webgpuProvider = '/home/x/deco/doe/packages/doe-gpu/src/index.js';
  const result = qualificationIdentity(contract, { W0: w0, D0: d0 });
  assert.equal(result.pass, false);
  assert.deepEqual(result.failed, ['D0.provider']);
});
