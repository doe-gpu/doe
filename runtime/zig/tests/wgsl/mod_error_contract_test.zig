// mod_error_contract_test.zig — Public WGSL translation error-contract tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const analyzeToIr = mod.analyzeToIr;
const TranslateError = mod.TranslateError;
const CompilationStage = mod.CompilationStage;
const lastErrorStage = mod.lastErrorStage;
const lastErrorKind = mod.lastErrorKind;
const lastErrorContext = mod.lastErrorContext;
const lastErrorInfo = mod.lastErrorInfo;
const lastErrorMessage = mod.lastErrorMessage;

test "semantic type mismatch preserves stage kind and source context" {
    try std.testing.expectError(TranslateError.UnexpectedToken, analyzeToIr(std.testing.allocator, "fn main("));
    try std.testing.expectEqual(CompilationStage.parser, lastErrorStage());
    try std.testing.expectEqual(TranslateError.UnexpectedToken, lastErrorKind().?);
    try std.testing.expect(std.mem.startsWith(u8, lastErrorMessage(), "parser:"));

    const source =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let value: bool = 1u;
        \\}
    ;
    try std.testing.expectError(TranslateError.TypeMismatch, analyzeToIr(std.testing.allocator, source));
    const info = lastErrorInfo();
    try std.testing.expectEqual(CompilationStage.sema, info.stage);
    try std.testing.expectEqual(TranslateError.TypeMismatch, info.kind.?);
    try std.testing.expect(info.location != null);
    try std.testing.expect(std.mem.indexOf(u8, info.context, "let value: bool = 1u;") != null);
    try std.testing.expect(std.mem.startsWith(u8, lastErrorMessage(), "sema: TypeMismatch"));
}

test "semantic unsupported builtin preserves specific error contract" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let value = transpose(1.0);
        \\}
    ;

    try std.testing.expectError(TranslateError.UnsupportedBuiltin, analyzeToIr(std.testing.allocator, source));
    try std.testing.expectEqual(CompilationStage.sema, lastErrorStage());
    try std.testing.expectEqual(TranslateError.UnsupportedBuiltin, lastErrorKind().?);
    try std.testing.expect(std.mem.indexOf(u8, lastErrorContext(), "transpose(1.0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), "UnsupportedBuiltin") != null);
}

test "ir builder unsupported construct preserves specific error contract" {
    const source =
        \\const FLAG: bool = !true;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;

    try std.testing.expectError(TranslateError.UnsupportedConstruct, analyzeToIr(std.testing.allocator, source));
    try std.testing.expectEqual(CompilationStage.ir_builder, lastErrorStage());
    try std.testing.expectEqual(TranslateError.UnsupportedConstruct, lastErrorKind().?);
    try std.testing.expect(std.mem.indexOf(u8, lastErrorContext(), "const FLAG: bool = !true;") != null);
    try std.testing.expect(std.mem.startsWith(u8, lastErrorMessage(), "ir_builder: UnsupportedConstruct"));
}

const analysis = @import("../../src/compiler/wgsl/pipeline/analysis.zig");
const translate_msl = @import("../../src/compiler/wgsl/pipeline/translate_msl.zig");
const DiagnosticCase = struct { source: []const u8, stage: CompilationStage, kind: TranslateError, context: []const u8 };
const DIAGNOSTIC_CASES = [_]DiagnosticCase{
    .{ .source = "\nfn broken(", .stage = .parser, .kind = error.UnexpectedToken, .context = "broken" },
    .{ .source = "@compute @workgroup_size(1)\nfn main() { let value: bool = 1u; }", .stage = .sema, .kind = error.TypeMismatch, .context = "value" },
    .{ .source = "const FLAG: bool = !true;\n@compute @workgroup_size(1) fn main() {}", .stage = .ir_builder, .kind = error.UnsupportedConstruct, .context = "FLAG" },
};
const VALID_DIAGNOSTIC_SOURCE = "@compute @workgroup_size(1) fn main() {}";

fn checkOwnedDiagnostic(case: DiagnosticCase) !void {
    var diagnostic = analysis.Diagnostic{};
    try std.testing.expectError(case.kind, analysis.analyzeToIrWithDiagnostic(std.heap.page_allocator, case.source, &diagnostic));
    const snapshot = diagnostic;
    var success = analysis.Diagnostic{};
    var module = try analysis.analyzeToIrWithDiagnostic(std.heap.page_allocator, VALID_DIAGNOSTIC_SOURCE, &success);
    defer module.deinit();
    try std.testing.expectEqual(CompilationStage.none, success.lastErrorStage());
    for (0..32) |_| {
        var other = analysis.Diagnostic{};
        try std.testing.expectError(error.UnexpectedToken, analysis.analyzeToIrWithDiagnostic(std.heap.page_allocator, "fn other(", &other));
        const info = diagnostic.lastErrorInfo();
        try std.testing.expectEqual(case.kind, info.kind.?);
        try std.testing.expectEqual(case.stage, info.stage);
        try std.testing.expect(info.location != null);
        try std.testing.expect(std.mem.indexOf(u8, info.context, case.context) != null);
        try std.testing.expectEqualSlices(u8, snapshot.last_error_buf[0..snapshot.last_error_len], diagnostic.lastErrorMessage());
    }
}

const DiagnosticThread = struct {
    case: DiagnosticCase,
    failure: ?anyerror = null,
    fn run(self: *DiagnosticThread) void {
        checkOwnedDiagnostic(self.case) catch |err| {
            self.failure = err;
        };
    }
};

test "owned diagnostics survive concurrent parser sema builder and successful compilations" {
    var workers: [DIAGNOSTIC_CASES.len]DiagnosticThread = undefined;
    var threads: [DIAGNOSTIC_CASES.len]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (DIAGNOSTIC_CASES, 0..) |case, i| {
        workers[i] = .{ .case = case };
        threads[i] = try std.Thread.spawn(.{}, DiagnosticThread.run, .{&workers[i]});
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    for (workers) |worker| if (worker.failure) |err| return err;
}

test "emission failures belong to the provided diagnostic" {
    var diagnostic = analysis.Diagnostic{};
    var output: [1]u8 = undefined;
    try std.testing.expectError(error.OutputTooLarge, translate_msl.translateToMslWithDiagnostic(std.testing.allocator, VALID_DIAGNOSTIC_SOURCE, &output, &diagnostic));
    try std.testing.expectEqual(CompilationStage.msl_emit, diagnostic.lastErrorStage());
    try std.testing.expectEqual(error.OutputTooLarge, diagnostic.lastErrorKind().?);
    _ = analyzeToIr(std.testing.allocator, "fn bad(") catch {};
    try std.testing.expectEqual(CompilationStage.msl_emit, diagnostic.lastErrorStage());
}
