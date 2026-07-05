const std = @import("std");
const ir = @import("../doe_wgsl/ir.zig");
const frontend_expr = @import("frontend_expr.zig");
const tsir = @import("mod.zig");
const types = @import("frontend_types.zig");

const FrontendError = types.FrontendError;

/// Walk the function body recursively and append one
/// `RejectionEntry` for every `while` / bare `loop` encountered
/// at any depth. Emitting these rejections is how the frontend
/// stays honest: per Step 4 of the TSIR plan, a source that
/// cannot be represented faithfully must reject with a typed
/// taxonomy reason rather than have its semantics silently
/// dropped. This pass mirrors `walkAxesInStmt` — both descend
/// through `block`, `if_` (then/else), and `loop_` bodies —
/// so a `while` nested inside a `for_loop` body still produces
/// a rejection instead of being invisibly absorbed.
///
/// `node_path` is a structured dot-delimited form. Top-level
/// non-for loops produce `functions[<i>].body[<k>]`; a non-for
/// nested inside an outer for at root position `k0` produces
/// `functions[<i>].body[<k0>].body[<k1>]`, and so on. Each
/// `.body[...]` segment corresponds to a block scope entered
/// during traversal. `detail` stays as a short noun phrase:
/// `"while loop"` or `"unstructured loop"`.
pub fn recoverRejections(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    func_index: u32,
    rejections: *std.ArrayList(tsir.schema.RejectionEntry),
) FrontendError!void {
    const root_prefix = try std.fmt.allocPrint(allocator, "functions[{d}]", .{func_index});
    defer allocator.free(root_prefix);
    try walkRejectionsInStmt(
        allocator,
        function,
        function.root_stmt,
        root_prefix,
        rejections,
    );
}

fn walkRejectionsInStmt(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    path_prefix: []const u8,
    rejections: *std.ArrayList(tsir.schema.RejectionEntry),
) FrontendError!void {
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                const child_id = function.stmt_children.items[range.start + i];
                const child_path = try std.fmt.allocPrint(
                    allocator,
                    "{s}.body[{d}]",
                    .{ path_prefix, i },
                );
                defer allocator.free(child_path);
                try walkRejectionsInStmt(allocator, function, child_id, child_path, rejections);
            }
        },
        .if_ => |node| {
            const then_prefix = try std.fmt.allocPrint(
                allocator,
                "{s}.then",
                .{path_prefix},
            );
            defer allocator.free(then_prefix);
            try walkRejectionsInStmt(allocator, function, node.then_block, then_prefix, rejections);
            if (node.else_block) |else_id| {
                const else_prefix = try std.fmt.allocPrint(
                    allocator,
                    "{s}.else",
                    .{path_prefix},
                );
                defer allocator.free(else_prefix);
                try walkRejectionsInStmt(allocator, function, else_id, else_prefix, rejections);
            }
        },
        .loop_ => |loop| {
            if (loop.kind != .for_loop) {
                const detail_literal: []const u8 = switch (loop.kind) {
                    .while_loop => "while loop",
                    .loop => "unstructured loop",
                    .for_loop => unreachable,
                };
                const detail_copy = try allocator.dupe(u8, detail_literal);
                const path_copy = try allocator.dupe(u8, path_prefix);
                try rejections.append(allocator, .{
                    .reason = .tsir_dependence_unanalyzable,
                    .node_path = path_copy,
                    .detail = detail_copy,
                });
            } else if (loop.init) |init_id| {
                const init_stmt = function.stmts.items[init_id];
                if (init_stmt == .local_decl and
                    frontend_expr.detectStepSign(function, loop.continuing, init_stmt.local_decl.local) == .negative)
                {
                    const detail_copy = try allocator.dupe(
                        u8,
                        "decreasing for-loop does not fit half-open iteration model",
                    );
                    const path_copy = try allocator.dupe(u8, path_prefix);
                    try rejections.append(allocator, .{
                        .reason = .tsir_source_not_affine,
                        .node_path = path_copy,
                        .detail = detail_copy,
                    });
                }
            }
            try walkRejectionsInStmt(allocator, function, loop.body, path_prefix, rejections);
            if (loop.continuing) |cont_id| {
                try walkRejectionsInStmt(allocator, function, cont_id, path_prefix, rejections);
            }
        },
        else => {},
    }
}
