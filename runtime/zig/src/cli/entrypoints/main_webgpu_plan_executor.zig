const doe = @import("doe");
const webgpu_plan_executor = doe.plan.webgpuExecutor();
const webgpu_plan_executor_cli = doe.plan.webgpuCli();

pub fn main() !void {
    try webgpu_plan_executor_cli.runCli(webgpu_plan_executor.runPlan);
}
