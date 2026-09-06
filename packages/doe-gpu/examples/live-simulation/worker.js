// One process owns one logical device and performs operations serially.
import { requestAdapter } from '../../src/native.js';
import { prepareComputeProgram } from '../../src/compute-program.js';
import { descriptor, parameters } from './program.js';

let adapter;
let device;
let program;
let pending;
let chain = Promise.resolve();

async function command(type, input) {
  switch (type) {
    case 'initialize': {
      if (device) throw new Error('worker is already initialized');
      adapter = await requestAdapter({ backend: input.backend });
      device = await adapter.requestDevice();
      program = await prepareComputeProgram(device, descriptor(input.code, input.stateFormat), {
        execution: input.execution,
      });
      return { preparationMs: program.preparationMs };
    }
    case 'step': {
      const values = { parameters: parameters(input.rate) };
      if (input.initial) values.state = input.initial;
      const result = await program.run(values);
      return { ...result, residentBytes: process.memoryUsage().rss };
    }
    case 'assess': {
      const next = descriptor(input.code, input.stateFormat);
      const assessment = program.assessUpdate(next);
      pending = { editId: input.editId, next, assessment };
      return assessment;
    }
    case 'activate': {
      if (!pending || pending.editId !== input.editId) throw new Error('stale edit approval');
      const edit = pending;
      pending = null;
      const started = performance.now();
      program = await program.update(edit.next, { assessment: edit.assessment,
        reset: input.approveReset ? 'approve' : 'preserve' });
      return { activationMs: performance.now() - started, preparationMs: program.preparationMs,
        reset: edit.assessment.requiresReset };
    }
    case 'discard': pending = null; return null;
    case 'close':
      await program?.close();
      device?.destroy();
      adapter?.destroy();
      return null;
    default: throw new Error(`unknown worker operation ${type}`);
  }
}

process.on('message', (message) => {
  chain = chain.then(async () => {
    try {
      const result = await command(message.type, message.input);
      process.send({ id: message.id, result }, (error) => {
        if (error) process.exitCode = 1;
        if (message.type === 'close') process.disconnect();
      });
    } catch (error) {
      process.send({ id: message.id, error: { code: error.code ?? 'DOE_LIVE_WORKER', message: error.message } });
    }
  }).catch(() => { process.exitCode = 1; process.disconnect(); });
});
