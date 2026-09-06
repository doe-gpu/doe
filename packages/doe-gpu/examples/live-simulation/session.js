// Application policy stays outside the runtime: preflight edits, then activate at a boundary.
import { EventEmitter } from 'node:events';
import { createHash } from 'node:crypto';
import { validateComputeProgram } from '../../src/compute-program.js';
import { createWorker } from './process.js';
import { POLICY, DEFAULT_SHADER, STATE_FORMAT, descriptor, parameters } from './program.js';
import { initialState, advanceReference, compareState } from './reference.js';

async function createLiveSimulation({ backend, execution, code = DEFAULT_SHADER }) {
  const events = new EventEmitter();
  const worker = createWorker();
  let candidate;
  let currentCode = code;
  let stateFormat = STATE_FORMAT;
  let rate = POLICY.rate;
  let expected = Float64Array.from(initialState());
  let initial = initialState();
  let iteration = 0;
  let editId = 0;
  let pendingReset;
  let timer;
  let paused = true;
  let closed = false;
  let closeTask;
  let failure;
  let frameWork = Promise.resolve();
  let control = Promise.resolve();
  let lastFrame;
  const initialization = await worker.call('initialize', { backend, execution, code, stateFormat }).catch(async (error) => {
    await worker.close(); throw error;
  });

  function emit(kind, detail = {}) { events.emit(kind, detail); events.emit('event', { kind, ...detail }); }
  function schedule() {
    clearTimeout(timer);
    if (!closed && !paused && !failure) timer = setTimeout(tick, POLICY.frameIntervalMs);
  }
  function tick() {
    const inputRate = rate;
    const started = performance.now();
    frameWork = worker.call('step', { rate: inputRate, initial }).then((result) => {
      const next = advanceReference(expected, inputRate);
      const maximumError = compareState(result.output, next);
      expected = next;
      initial = null;
      iteration += 1;
      lastFrame = { iteration, rate: inputRate, maximumError, operationMs: performance.now() - started,
        residentBytes: result.residentBytes, receipt: result.receipt };
      emit('frame', lastFrame);
    }).catch((error) => {
      failure = error;
      paused = true;
      emit('failure', { message: error.message });
    }).finally(schedule);
  }
  function assertOpen() {
    if (closed || failure) throw failure ?? new Error('simulation is closed');
  }
  function atBoundary(action) {
    const task = control.then(async () => {
      assertOpen();
      paused = true;
      clearTimeout(timer);
      await frameWork;
      assertOpen();
      try { return await action(); }
      finally { paused = Boolean(pendingReset); schedule(); }
    });
    control = task.catch(() => {});
    return task;
  }
  async function activate(edit, approveReset) {
    emit('activating', { editId: edit.id });
    const result = await worker.call('activate', { editId: edit.id, approveReset });
    currentCode = edit.code;
    stateFormat = edit.stateFormat;
    if (result.reset) {
      initial = initialState();
      expected = Float64Array.from(initial);
    }
    const response = { editId: edit.id, ...result,
      shaderSha256: createHash('sha256').update(currentCode).digest('hex') };
    emit('activated', response);
    return { status: 'activated', ...response };
  }
  async function propose(nextCode, nextFormat = stateFormat) {
    assertOpen();
    validateComputeProgram(descriptor(nextCode, nextFormat));
    const id = ++editId;
    candidate?.abort(new Error('obsolete edit cancelled'));
    const preflight = createWorker();
    candidate = preflight;
    const firstIteration = iteration;
    emit('preparing', { editId: id });
    try {
      await atBoundary(async () => {
        if (pendingReset) { pendingReset = null; await worker.call('discard'); }
      });
      await preflight.call('initialize', { backend, execution, code: nextCode, stateFormat: nextFormat });
      for (const inputKind of POLICY.candidateInputs) {
        for (const testRate of POLICY.candidateRates) {
          const input = initialState(inputKind);
          let reference = Float64Array.from(input);
          for (let step = 0; step < POLICY.candidateSteps; step += 1) {
            const result = await preflight.call('step', { rate: testRate, initial: step === 0 ? input : null });
            reference = advanceReference(reference, testRate);
            compareState(result.output, reference);
          }
          emit('checking', { editId: id, inputKind, rate: testRate });
        }
      }
      await preflight.close();
      if (id !== editId || closed) return { status: 'cancelled', editId: id };
      return await atBoundary(async () => {
        if (id !== editId) return { status: 'cancelled', editId: id };
        const assessment = await worker.call('assess', { editId: id, code: nextCode, stateFormat: nextFormat });
        const edit = { id, code: nextCode, stateFormat: nextFormat, assessment };
        emit('checked', { editId: id, framesDuringPreflight: iteration - firstIteration });
        if (assessment.requiresReset) {
          pendingReset = edit;
          emit('reset-required', { editId: id, assessment });
          return { status: 'reset-required', editId: id, assessment };
        }
        return activate(edit, false);
      });
    } catch (error) {
      if (id !== editId || closed) return { status: 'cancelled', editId: id };
      const response = { status: 'rejected', editId: id, code: error.code ?? 'DOE_LIVE_CANDIDATE', message: error.message };
      emit('rejected', response);
      return response;
    } finally {
      await preflight.close();
      if (candidate === preflight) candidate = null;
    }
  }

  paused = false;
  schedule();
  return {
    events, initialization, propose,
    get shaderSource() { return currentCode; },
    get status() { return { iteration, paused, closed, failed: failure?.message ?? null,
      pendingEditId: pendingReset?.id ?? null, stateFormat, lastFrame }; },
    setRate(nextRate) { assertOpen(); parameters(nextRate); rate = nextRate; },
    async decideReset(id, approve) {
      if (typeof approve !== 'boolean') throw new TypeError('reset decision must be an explicit boolean');
      return atBoundary(async () => {
        if (!pendingReset || pendingReset.id !== id) throw new Error('stale reset decision');
        const edit = pendingReset;
        pendingReset = null;
        if (approve) return activate(edit, true);
        await worker.call('discard');
        emit('declined', { editId: id });
        return { status: 'declined', editId: id };
      });
    },
    cancelEdit() {
      assertOpen();
      editId += 1;
      candidate?.abort(new Error('edit cancelled'));
      return atBoundary(async () => {
        if (pendingReset) { pendingReset = null; await worker.call('discard'); }
      });
    },
    close() {
      if (closeTask) return closeTask;
      closed = true;
      clearTimeout(timer);
      candidate?.abort(new Error('session closed'));
      closeTask = (async () => {
        await control;
        await frameWork;
        await worker.close();
      })();
      return closeTask;
    },
  };
}

export { createLiveSimulation };
