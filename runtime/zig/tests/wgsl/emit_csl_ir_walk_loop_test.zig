// emit_csl_ir_walk_loop_test.zig — regression test for the WGSL for-loop
// continuing-clause emission path.
//
// The bug this locks in: before iteration 15, the .loop_ case in
// stmt() recursively called stmt() on the continuing statement, which
// always appends `;\n`. Wrapped in `while (cond) : (<continuing>) { ... }`
// this produced malformed CSL like:
//
//     while ((i < 256)) : (i = (i + 1);
//     ) {
//
// cslc rejects the dangling semicolon+newline before the closing paren.
// The fix routes the continuing clause through continuingStmt(), which
// emits the expression inline without the trailing `;\n`.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const allocator = std.testing.allocator;

// A minimal WGSL shader with a C-style for-loop; the for-loop's
// continuing-expression is what lands in the CSL continuing clause.
const FOR_LOOP_WGSL =
    "@group(0) @binding(0) var<storage, read> input: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> out: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3u) {\n" ++
    "    var sum: f32 = 0.0;\n" ++
    "    for (var i: u32 = 0u; i < 256u; i = i + 1u) {\n" ++
    "        sum = sum + input[i];\n" ++
    "    }\n" ++
    "    out[gid.x] = sum;\n" ++
    "}\n";

test "emit_csl_ir_walk: for-loop continuing clause has no stray semicolon" {
    var buf: [32 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, FOR_LOOP_WGSL, &buf);
    const csl = buf[0..written];

    // The continuing expression must land inside `: (...)` parens with
    // NO trailing `;` or newline. Search for the closing paren pattern
    // the fix guarantees.
    const has_clean_continue = std.mem.indexOf(u8, csl, ") : (i = (i + 1)) {") != null or
        std.mem.indexOf(u8, csl, ") : (i = i + 1) {") != null;
    if (!has_clean_continue) {
        std.debug.print("missing clean `: (cont) {{` pattern. Output:\n{s}\n", .{csl});
        return error.ForContinueEmissionRegressed;
    }

    // Absolutely reject the pre-fix shape: `;\n` before the continue's
    // closing paren. Two specific broken forms to catch.
    const broken_patterns = [_][]const u8{
        "i + 1);\n) {",
        "i + 1u);\n) {",
        "i + 1)));\n)",
    };
    for (broken_patterns) |pat| {
        if (std.mem.indexOf(u8, csl, pat) != null) {
            std.debug.print("found broken for-continue pattern `{s}` in:\n{s}\n", .{ pat, csl });
            return error.ForContinueHasStraySemicolon;
        }
    }
}
