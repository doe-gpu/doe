export function summarizeOwnershipLane(runs, laneId) {
  const laneRuns = runs.filter((run) => run.laneId === laneId);
  if (laneRuns.length === 0) {
    return null;
  }
  const successfulRuns = laneRuns.filter((run) => (
    run.success === true
    || (run.exitCode === 0 && !run.timedOut && run.result)
  )).length;
  const contractCompleteRuns = laneRuns.filter(
    (run) => run.contractComplete !== false,
  ).length;
  const executionPassed = successfulRuns === laneRuns.length;
  const contractComplete = contractCompleteRuns === laneRuns.length;
  return {
    status: executionPassed && contractComplete
      ? 'passed'
      : executionPassed
        ? 'partial'
        : 'failed',
    runCount: laneRuns.length,
    successfulRuns,
    contractCompleteRuns,
    constructionIssues: [...new Set(laneRuns.flatMap((run) => run.constructionIssues ?? []))],
    providerModulePaths: [...new Set(
      laneRuns
        .map((run) => run.providerModulePath)
        .filter((path) => typeof path === 'string' && path.length > 0),
    )],
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
      contractCompleteRuns: 0,
      constructionIssues: [],
      providerModulePaths: [],
      runs: [],
    };
  }
  const incompleteRequiredLanes = Object.entries(lanes)
    .filter(([laneId, lane]) => (
      plan.lanes[laneId].requirement === 'required'
      && ['not-run', 'unavailable', 'partial'].includes(lane.status)
    ))
    .map(([laneId]) => laneId);
  return {
    status: incompleteRequiredLanes.length === 0 ? 'complete' : 'diagnostic-incomplete',
    planSha256,
    claimedProperty: plan.claimedProperty,
    missingRequiredLanes: incompleteRequiredLanes,
    ambientModuleSupplied,
    lanes,
  };
}
