// Shared child/process-group termination; callers own deadlines and receipts.
function terminateProcess(child, terminationScope) {
  if (!child?.pid) return;
  if (terminationScope === 'process-group') {
    try {
      process.kill(-child.pid, 'SIGKILL');
      return;
    } catch {
      // Fall through to the direct child when the group is already gone.
    }
  }
  try {
    child.kill('SIGKILL');
  } catch {
    // The child already terminated.
  }
}

export { terminateProcess };
