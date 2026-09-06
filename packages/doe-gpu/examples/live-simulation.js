#!/usr/bin/env node
// A terminal workspace for a resident heat field and externally edited WGSL.
import { readFileSync, statSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { parseArgs } from 'node:util';
import { createLiveSimulation } from './live-simulation/session.js';
import { DEFAULT_SHADER, POLICY } from './live-simulation/program.js';

const { values } = parseArgs({ options: {
  backend: { type: 'string' }, execution: { type: 'string' },
  'write-shader': { type: 'string' },
} });
if (values['write-shader']) {
  writeFileSync(values['write-shader'], DEFAULT_SHADER, { flag: 'wx' });
  console.log(`Created ${values['write-shader']}`);
} else {
  if (!['vulkan', 'metal'].includes(values.backend)
      || !['gpu-recorded', 'native-recorded', 'webgpu'].includes(values.execution)) {
    throw new Error('Usage: node examples/live-simulation.js --backend vulkan|metal --execution gpu-recorded|native-recorded|webgpu; or --write-shader path.wgsl');
  }
  const session = await createLiveSimulation({ backend: values.backend, execution: values.execution });
  const input = createInterface({ input: process.stdin, output: process.stdout, terminal: process.stdin.isTTY });
  let stopping = false;
  async function close() {
    if (stopping) return;
    stopping = true;
    input.close();
    await session.close();
  }
  session.events.on('event', (event) => {
    if (event.kind === 'frame') {
      if (event.iteration % POLICY.statusEveryFrames === 0) {
        console.log(`iteration ${event.iteration}; rate ${event.rate}; checked operation ${event.operationMs.toFixed(3)}ms; maximum error ${event.maximumError}`);
      }
      return;
    }
    if (event.kind === 'activated') {
      console.log(`edit ${event.editId} activated; pause ${event.activationMs.toFixed(3)}ms; state ${event.reset ? 'reset' : 'retained'}`);
    } else if (event.kind === 'reset-required') {
      console.log(`edit ${event.editId} would reset state; paused. Enter approve ${event.editId} or decline ${event.editId}.`);
    } else if (event.kind === 'failure') {
      console.error(`simulation stopped: ${event.message}`);
      process.exitCode = 1;
      void close();
    } else {
      console.log(`${event.kind}${event.editId ? ` edit ${event.editId}` : ''}${event.message ? `: ${event.message}` : ''}`);
    }
  });
  input.on('line', (line) => {
    const [command, ...words] = line.trim().split(/\s+/);
    const argument = words.join(' ');
    void (async () => {
      switch (command) {
        case 'edit':
          if (statSync(argument).size > POLICY.maximumShaderBytes) throw new Error('shader exceeds configured size limit');
          await session.propose(readFileSync(argument, 'utf8'));
          break;
        case 'format': await session.propose(session.shaderSource, argument); break;
        case 'rate': session.setRate(Number(argument)); break;
        case 'approve': await session.decideReset(Number(argument), true); break;
        case 'decline': await session.decideReset(Number(argument), false); break;
        case 'cancel': await session.cancelEdit(); break;
        case 'save': writeFileSync(argument, session.shaderSource, { flag: 'wx' }); break;
        case 'status': console.log(session.status); break;
        case 'quit': await close(); break;
        default: console.log('Commands: edit path.wgsl | rate value | format state-format | approve id | decline id | cancel | save path.wgsl | status | quit');
      }
    })().catch((error) => console.error(error.message));
  });
  input.on('close', () => { void close(); });
  process.once('SIGINT', () => { void close(); });
  console.log(`Running ${POLICY.width}x${POLICY.height} heat simulation on ${values.backend}/${values.execution}.`);
  console.log('Commands: edit path.wgsl | rate value | format state-format | approve id | decline id | cancel | save path.wgsl | status | quit');
}
