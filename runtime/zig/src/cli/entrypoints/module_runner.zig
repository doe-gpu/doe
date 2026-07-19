const module_runner_cli = @import("doe").cli.moduleRunner();

pub const RunnerError = module_runner_cli.RunnerError;

pub fn main() !void {
    try module_runner_cli.runCli();
}
