export function summarizeOwnershipLane(runs, laneId) {
  const laneRuns = runs.filter((run) => run.laneId === laneId);
  if (laneRuns.length === 0) {
    return null;
  }
  const successfulRuns = laneRuns.filter(
    (run) => run.exitCode === 0 && !run.timedOut && run.result,
  ).length;
  return {
    status: successfulRuns === laneRuns.length ? 'passed' : 'failed',
    runCount: laneRuns.length,
    successfulRuns,
    providerModulePaths: [...new Set(laneRuns.map((run) => run.providerModulePath))],
    runs: laneRuns,
  };
}

export function buildRuntimeOwnership({
  runs,
  plan,
  planSha256,
  ambientModuleSupplied,
}) {
  const lanes = {};
  for (const laneId of ['I0', 'I1', 'W0', 'D0', 'P0']) {
    lanes[laneId] = summarizeOwnershipLane(runs, laneId) ?? {
      status: laneId === 'I0' && !ambientModuleSupplied ? 'unavailable' : 'not-run',
      runCount: 0,
      successfulRuns: 0,
      providerModulePaths: [],
      runs: [],
    };
  }
  const missingRequiredLanes = Object.entries(lanes)
    .filter(([laneId, lane]) => (
      plan.lanes[laneId].requirement === 'required' && lane.status !== 'passed'
    ))
    .map(([laneId]) => laneId);
  return {
    status: missingRequiredLanes.length === 0 ? 'complete' : 'diagnostic-incomplete',
    planSha256,
    claimedProperty: plan.claimedProperty,
    missingRequiredLanes,
    ambientModuleSupplied,
    lanes,
  };
}
