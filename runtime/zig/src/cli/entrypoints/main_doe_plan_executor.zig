const doe = @import("doe");
const doe_plan_executor = doe.plan.doeExecutor();
const doe_plan_executor_cli = doe.cli.doePlanExecutor();

pub fn main() !void {
    try doe_plan_executor_cli.runCli(doe_plan_executor.runPlan);
}
