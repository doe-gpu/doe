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
