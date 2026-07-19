const runtime_cli = @import("doe").cli.runtime();

pub fn main() !void {
    try runtime_cli.runCli();
}
