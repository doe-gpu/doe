// Complete submission and readback without serial host polling waits.
import { globals } from './vendor/webgpu/webgpu-constants.js';

async function awaitProgramCompletion(queue, readback) {
  const completion = queue.onSubmittedWorkDone();
  if (!readback) return completion;
  const mapping = Promise.resolve().then(() => readback.mapAsync(globals.GPUMapMode.READ));
  // A failed promise must not release resources while the other is pending.
  const [completed, mapped] = await Promise.allSettled([completion, mapping]);
  if (completed.status === 'rejected' || mapped.status === 'rejected') {
    if (mapped.status === 'fulfilled') readback.unmap();
    throw completed.status === 'rejected' ? completed.reason : mapped.reason;
  }
}

export { awaitProgramCompletion };
