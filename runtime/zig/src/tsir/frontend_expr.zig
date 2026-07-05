const std = @import("std");
const ir = @import("../doe_wgsl/ir.zig");
const types = @import("frontend_types.zig");

const FrontendError = types.FrontendError;

/// Extract a literal upper bound from a for-loop condition
/// shaped as any of `i < N`, `i <= N`, `N > i`, or `N >= i`
/// where `i` is the induction variable and `N` is an integer
/// literal. Returns `null` when the condition isn't one of
/// these — the caller falls back to the placeholder string
/// so non-literal bounds don't lie about being analyzable.
///
/// Convention: `upper_bound` is exclusive. The mapping mirrors
/// the polarity:
///   - `i < N` or `N > i` (strict)      → `N`
///   - `i <= N` or `N >= i` (non-strict) → `N + 1`
///
/// Rationale for the mirror forms: some authors write
/// `for (var i: u32 = 0u; 4u > i; i = i + 1u)` instead of the
/// canonical `i < 4u`. Semantically identical; without mirror
/// handling the second form collapses to the
/// `"upper_bound"` placeholder and a digest-wise-distinct
/// kernel is created where none should exist.
pub fn extractLiteralUpperBound(
    function: *const ir.Function,
    cond_opt: ?ir.ExprId,
    induction_local: u32,
) ?u64 {
    const cond_id = cond_opt orelse return null;
    const cond_node = function.exprs.items[cond_id];
    if (cond_node.data != .binary) return null;
    const binary = cond_node.data.binary;

    const Shape = struct { op: ir.BinaryOp, literal: u64 };
    const shape: Shape = switch (binary.op) {
        .less, .less_equal => blk: {
            const lhs_node = function.exprs.items[binary.lhs];
            if (lhs_node.data != .load) return null;
            const lhs_ref = function.exprs.items[lhs_node.data.load];
            if (lhs_ref.data != .local_ref) return null;
            if (lhs_ref.data.local_ref != induction_local) return null;
            const rhs_node = function.exprs.items[binary.rhs];
            if (rhs_node.data != .int_lit) return null;
            break :blk .{ .op = binary.op, .literal = rhs_node.data.int_lit };
        },
        .greater, .greater_equal => blk: {
            // Mirror: `N > i` or `N >= i`. Induction is on the
            // rhs, literal on the lhs. Translate to equivalent
            // `i < N` / `i <= N` bounds.
            const rhs_node = function.exprs.items[binary.rhs];
            if (rhs_node.data != .load) return null;
            const rhs_ref = function.exprs.items[rhs_node.data.load];
            if (rhs_ref.data != .local_ref) return null;
            if (rhs_ref.data.local_ref != induction_local) return null;
            const lhs_node = function.exprs.items[binary.lhs];
            if (lhs_node.data != .int_lit) return null;
            const mirrored: ir.BinaryOp = switch (binary.op) {
                .greater => .less,
                .greater_equal => .less_equal,
                else => unreachable,
            };
            break :blk .{ .op = mirrored, .literal = lhs_node.data.int_lit };
        },
        else => return null,
    };

    return switch (shape.op) {
        .less => shape.literal,
        .less_equal => shape.literal +% 1,
        else => unreachable,
    };
}

/// Decide whether an assign statement inside a loop body looks like
/// a reduction update on a local accumulator. Returns the mapped
/// `ReductionOp` when the pattern is recognized, `null` otherwise.
/// Resolve a for-loop condition shaped `i < X` or `i <= X` where
/// `X` is a module-scope `override` or `const` global reference.
/// Emits a symbolic bound string so the axis digest distinguishes
/// kernels that differ only in the named bound. Returns `null`
/// when the rhs doesn't resolve to an override/const reference —
/// uniform buffer loads and arithmetic expressions stay on the
/// placeholder path until a later increment extends the grammar.
///
/// Output shape: `"override:<name>"` for `i < N`, `"override:<name>+1"`
/// for `i <= N` (exclusive-bound convention mirroring the literal
/// path). Same convention applied for `const_` globals with the
/// `"const:"` prefix so consumers can distinguish rebindable
/// overrides from immutable constants. Returned slice is owned
/// by the caller (allocated via `allocator`).
pub fn extractSymbolicUpperBound(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    cond_opt: ?ir.ExprId,
    induction_local: u32,
) FrontendError!?[]const u8 {
    const cond_id = cond_opt orelse return null;
    const cond_node = function.exprs.items[cond_id];
    if (cond_node.data != .binary) return null;
    const binary = cond_node.data.binary;

    // Accept both canonical forms (`i <? name`) and mirror forms
    // (`name >? i`); translate both into a (name_expr_id,
    // effective_op) pair where effective_op is `.less` or
    // `.less_equal` so the symbolic-emit logic below can stay
    // polarity-agnostic.
    const effective_op: ir.BinaryOp = switch (binary.op) {
        .less, .less_equal => blk: {
            const lhs_node = function.exprs.items[binary.lhs];
            if (lhs_node.data != .load) return null;
            const lhs_ref = function.exprs.items[lhs_node.data.load];
            if (lhs_ref.data != .local_ref) return null;
            if (lhs_ref.data.local_ref != induction_local) return null;
            break :blk binary.op;
        },
        .greater, .greater_equal => blk: {
            const rhs_node = function.exprs.items[binary.rhs];
            if (rhs_node.data != .load) return null;
            const rhs_ref = function.exprs.items[rhs_node.data.load];
            if (rhs_ref.data != .local_ref) return null;
            if (rhs_ref.data.local_ref != induction_local) return null;
            break :blk switch (binary.op) {
                .greater => .less,
                .greater_equal => .less_equal,
                else => unreachable,
            };
        },
        else => return null,
    };
    const name_expr_id = switch (binary.op) {
        .less, .less_equal => binary.rhs,
        .greater, .greater_equal => binary.lhs,
        else => unreachable,
    };

    const suffix: []const u8 = if (effective_op == .less_equal) "+1" else "";

    // Uniform struct-field path: `i < params.count` where params is
    // a module-scope uniform. Preferred over the bare global path
    // because the field name carries semantic identity the plain
    // struct name would lose.
    if (extractUniformFieldAccess(function, name_expr_id)) |mem| {
        if (mem.global_index < module.globals.items.len) {
            const g = module.globals.items[mem.global_index];
            if (g.class == .var_ and g.addr_space == .uniform) {
                return try std.fmt.allocPrint(
                    allocator,
                    "uniform:{s}.{s}{s}",
                    .{ g.name, mem.field_name, suffix },
                );
            }
        }
    }

    const global_index = findGlobalBase(function, name_expr_id) orelse return null;
    if (global_index >= module.globals.items.len) return null;
    const g = module.globals.items[global_index];
    const base = (try writeOverrideOrConstName(allocator, g)) orelse return null;
    defer allocator.free(base);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
}

/// Extract the step string from a for-loop's `continuing` clause.
/// Recognized shapes mirror `detectReductionOp`'s two self-update
/// patterns applied to the induction variable:
///
///   - **Compound assign** (`i += N` / `i -= N`): the IR's
///     `AssignOp` is `.add` / `.sub` with lhs `local_ref(i)`.
///   - **Expanded self-update** (`i = i + N` / `i = i - N`): the
///     assign op is `.assign` and the rhs is a `.binary` whose
///     left side is a `.load` of the induction variable.
///
/// `N` is emitted as:
///   - decimal literal for `int_lit`,
///   - `uniform:<struct>.<field>` for a uniform struct field,
///   - `override:<name>` / `const:<name>` for module-scope
///     overrides / consts.
///
/// Returns `null` when the continuing clause doesn't match these
/// shapes; the caller falls through to `"1"` so the canonical
/// `i = i + 1u` kernel stays digest-stable (it also flows
/// through the int_lit path and still emits `"1"`).
pub fn extractStep(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    cont_opt: ?ir.StmtId,
    induction_local: u32,
) FrontendError!?[]const u8 {
    const cont_id = cont_opt orelse return null;
    const cont_stmt = function.stmts.items[cont_id];
    if (cont_stmt != .assign) return null;
    const assign = cont_stmt.assign;

    // lhs must resolve to the induction local_ref (no load — this
    // is an assign target, not a value load).
    const lhs_node = function.exprs.items[assign.lhs];
    if (lhs_node.data != .local_ref) return null;
    if (lhs_node.data.local_ref != induction_local) return null;

    // Pick the expression whose value is `N`:
    //   - Compound assign (`i += N`): `assign.rhs` IS `N`.
    //   - Expanded (`i = i + N`): `assign.rhs` is `binary`, take
    //     `rhs.rhs` as the literal `N` side (after confirming the
    //     binary's lhs is `load(local_ref(i))`).
    var value_expr_id = assign.rhs;
    const prefix: []const u8 = switch (assign.op) {
        .add => "",
        .sub => "-",
        .assign => blk: {
            const rhs_node = function.exprs.items[assign.rhs];
            if (rhs_node.data != .binary) return null;
            const binary = rhs_node.data.binary;
            const binary_lhs_node = function.exprs.items[binary.lhs];
            if (binary_lhs_node.data != .load) return null;
            const inner = function.exprs.items[binary_lhs_node.data.load];
            if (inner.data != .local_ref) return null;
            if (inner.data.local_ref != induction_local) return null;
            value_expr_id = binary.rhs;
            break :blk switch (binary.op) {
                .add => "",
                .sub => "-",
                else => return null,
            };
        },
        else => return null,
    };

    const value_node = function.exprs.items[value_expr_id];
    if (value_node.data == .int_lit) {
        return try std.fmt.allocPrint(
            allocator,
            "{s}{d}",
            .{ prefix, value_node.data.int_lit },
        );
    }

    if (extractUniformFieldAccess(function, value_expr_id)) |mem| {
        if (mem.global_index < module.globals.items.len) {
            const g = module.globals.items[mem.global_index];
            if (g.class == .var_ and g.addr_space == .uniform) {
                return try std.fmt.allocPrint(
                    allocator,
                    "{s}uniform:{s}.{s}",
                    .{ prefix, g.name, mem.field_name },
                );
            }
        }
    }

    if (findGlobalBase(function, value_expr_id)) |global_index| {
        if (global_index < module.globals.items.len) {
            const g = module.globals.items[global_index];
            if (try writeOverrideOrConstName(allocator, g)) |base| {
                defer allocator.free(base);
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, base });
            }
        }
    }

    return null;
}

/// Resolve the initializer expression of a for-loop's induction
/// variable into a lower-bound string. Handles integer literals
/// directly (`for (var i: u32 = 4u; ...)` → `"4"`), uniform
/// struct fields (`for (var i: u32 = params.offset; ...)` →
/// `"uniform:params.offset"`), and module-scope override / const
/// references (`for (var i: u32 = start; ...)` →
/// `"override:start"` / `"const:start"`). Returns `null` for
/// anything else so the caller falls through to the `"0"`
/// default, which matches the canonical `i = 0u` init the axis
/// walker historically assumed.
pub fn extractInitBound(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    init_expr_opt: ?ir.ExprId,
) FrontendError!?[]const u8 {
    const init_id = init_expr_opt orelse return null;
    const init_node = function.exprs.items[init_id];

    if (init_node.data == .int_lit) {
        return try std.fmt.allocPrint(allocator, "{d}", .{init_node.data.int_lit});
    }

    if (extractUniformFieldAccess(function, init_id)) |mem| {
        if (mem.global_index < module.globals.items.len) {
            const g = module.globals.items[mem.global_index];
            if (g.class == .var_ and g.addr_space == .uniform) {
                return try std.fmt.allocPrint(
                    allocator,
                    "uniform:{s}.{s}",
                    .{ g.name, mem.field_name },
                );
            }
        }
    }

    if (findGlobalBase(function, init_id)) |global_index| {
        if (global_index < module.globals.items.len) {
            const g = module.globals.items[global_index];
            if (try writeOverrideOrConstName(allocator, g)) |base| {
                return base;
            }
        }
    }

    return null;
}

/// Scan forward in a block looking for the early-return guard
/// that bounds `dispatch_local`. Multi-axis dispatch kernels
/// commonly interleave several `let X = gid.*` decls with
/// sibling guards:
///
/// ```
/// let t = gid.y;
/// let h = gid.x;
/// if (t >= u.num_tokens) { return; }
/// if (h >= u.hidden) { return; }
/// ```
///
/// The single-sibling peek used to match only the first case —
/// the one whose guard sits immediately after its decl. Scanning
/// past skip-safe siblings (other local_decls; early-return
/// guards for OTHER axes) lets every dispatch axis still resolve
/// its real bound. Anything that isn't a skip-safe shape
/// (arithmetic assigns, returns, for-loops, non-guard ifs) stops
/// the scan and falls through to the placeholder.
pub fn scanForDispatchGuard(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    body_range: ir.Range,
    start_pos: u32,
    dispatch_local: u32,
) FrontendError!?[]const u8 {
    var k: u32 = start_pos + 1;
    while (k < body_range.len) : (k += 1) {
        const stmt_id = function.stmt_children.items[body_range.start + k];
        const stmt = function.stmts.items[stmt_id];
        switch (stmt) {
            .local_decl => continue,
            .if_ => |if_node| {
                if (try extractDispatchBoundFromGuard(
                    allocator,
                    module,
                    function,
                    stmt_id,
                    dispatch_local,
                )) |s| return s;

                // Not our guard. Skip past it only when it's a
                // bare early-return for SOME OTHER local — any
                // structural divergence (else branch, multi-stmt
                // then-body without a return) stops the scan
                // since we can't reason about execution paths
                // that survive past it.
                if (if_node.else_block != null) return null;
                const then_stmt = function.stmts.items[if_node.then_block];
                const is_early_return = switch (then_stmt) {
                    .return_ => true,
                    .block => |r| blk: {
                        if (r.len != 1) break :blk false;
                        const inner_id = function.stmt_children.items[r.start];
                        break :blk function.stmts.items[inner_id] == .return_;
                    },
                    else => false,
                };
                if (!is_early_return) return null;
            },
            else => return null,
        }
    }
    return null;
}

/// Detect `if (i >= bound) { return; }` / `if (i > bound) ...`
/// early-return guard statements immediately following a
/// dispatch-axis `local_decl`. Returns the resolved upper_bound
/// string when the shape matches — literal, uniform-struct
/// field, override, or const — or `null` otherwise so the
/// caller falls back to the `"dispatch.x"` placeholder.
///
/// Semantic mapping: the guard early-returns when the condition
/// is true, so the VALID range of the dispatch local is the
/// complement of the guard. `i >= M` → valid range `[0, M)` →
/// upper_bound = `M` (no suffix). `i > M` → valid range
/// `[0, M]` → upper_bound = `M + 1` under the exclusive-bound
/// convention (suffix `"+1"`).
///
/// Structural checks: the statement must be an `if` with no
/// else branch whose then-body is either a bare `return` or a
/// single-statement block containing a return. This is narrow
/// on purpose — other guard shapes (side effects, multi-stmt
/// then, conditional writes) keep the axis on the placeholder
/// until the walker grows richer.
fn extractDispatchBoundFromGuard(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    guard_stmt_id: ir.StmtId,
    dispatch_local: u32,
) FrontendError!?[]const u8 {
    const stmt = function.stmts.items[guard_stmt_id];
    if (stmt != .if_) return null;
    const if_ = stmt.if_;
    if (if_.else_block != null) return null;

    // then must be a bare return or a block containing one return
    const then_stmt = function.stmts.items[if_.then_block];
    switch (then_stmt) {
        .return_ => {},
        .block => |r| {
            if (r.len != 1) return null;
            const inner_id = function.stmt_children.items[r.start];
            const inner = function.stmts.items[inner_id];
            if (inner != .return_) return null;
        },
        else => return null,
    }

    const cond_node = function.exprs.items[if_.cond];
    if (cond_node.data != .binary) return null;
    const binary = cond_node.data.binary;
    if (binary.op != .greater and binary.op != .greater_equal) return null;

    // lhs must be `load(local_ref(dispatch_local))`
    const lhs_node = function.exprs.items[binary.lhs];
    if (lhs_node.data != .load) return null;
    const lhs_ref = function.exprs.items[lhs_node.data.load];
    if (lhs_ref.data != .local_ref) return null;
    if (lhs_ref.data.local_ref != dispatch_local) return null;

    const suffix: []const u8 = if (binary.op == .greater) "+1" else "";

    // Literal bound
    const rhs_node = function.exprs.items[binary.rhs];
    if (rhs_node.data == .int_lit) {
        return try std.fmt.allocPrint(
            allocator,
            "{d}{s}",
            .{ rhs_node.data.int_lit, suffix },
        );
    }

    // Uniform struct-field bound
    if (extractUniformFieldAccess(function, binary.rhs)) |mem| {
        if (mem.global_index < module.globals.items.len) {
            const g = module.globals.items[mem.global_index];
            if (g.class == .var_ and g.addr_space == .uniform) {
                return try std.fmt.allocPrint(
                    allocator,
                    "uniform:{s}.{s}{s}",
                    .{ g.name, mem.field_name, suffix },
                );
            }
        }
    }

    // Override / const bound
    if (findGlobalBase(function, binary.rhs)) |global_index| {
        if (global_index < module.globals.items.len) {
            const g = module.globals.items[global_index];
            if (try writeOverrideOrConstName(allocator, g)) |base| {
                defer allocator.free(base);
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
            }
        }
    }

    return null;
}

pub const StepSign = enum { positive, negative, unknown };

/// Classify a for-loop's `continuing` clause as increasing,
/// decreasing, or unknown WITHOUT allocating a step string. The
/// axis, reduction, and collective walkers all call this to
/// decide whether to emit/increment for the loop, and the
/// rejection pass uses it to escalate decreasing loops to a
/// typed rejection.
///
/// Recognized shapes mirror `extractStep`: compound
/// `i += N` / `i -= N` and expanded `i = i + N` / `i = i - N`.
/// Anything else returns `.unknown` — treated as positive by
/// the axis/reduction/collective walkers (so "can't prove it's
/// decreasing" doesn't reject an otherwise-recognizable loop),
/// but the rejection pass uses strict `.negative` checks so it
/// never emits a false-positive rejection either.
pub fn detectStepSign(
    function: *const ir.Function,
    cont_opt: ?ir.StmtId,
    induction_local: u32,
) StepSign {
    const cont_id = cont_opt orelse return .unknown;
    const cont_stmt = function.stmts.items[cont_id];
    if (cont_stmt != .assign) return .unknown;
    const assign = cont_stmt.assign;

    const lhs_node = function.exprs.items[assign.lhs];
    if (lhs_node.data != .local_ref) return .unknown;
    if (lhs_node.data.local_ref != induction_local) return .unknown;

    switch (assign.op) {
        .add => return .positive,
        .sub => return .negative,
        .assign => {
            const rhs_node = function.exprs.items[assign.rhs];
            if (rhs_node.data != .binary) return .unknown;
            const binary = rhs_node.data.binary;
            const binary_lhs_node = function.exprs.items[binary.lhs];
            if (binary_lhs_node.data != .load) return .unknown;
            const inner = function.exprs.items[binary_lhs_node.data.load];
            if (inner.data != .local_ref) return .unknown;
            if (inner.data.local_ref != induction_local) return .unknown;
            return switch (binary.op) {
                .add => .positive,
                .sub => .negative,
                else => .unknown,
            };
        },
        else => return .unknown,
    }
}

/// Format a module-scope `override` or `const` global as a
/// symbolic identifier used in axis bound strings. Prefer the
/// `@id(N)` pipeline constant id over the textual name when it's
/// present — the id is the stable identity across renames, so
/// the resulting digest does not fork when a kernel's override
/// is renamed. Returns `null` for globals that aren't symbolic
/// bound candidates (var_ / input / output classes). Returned
/// slice is owned by the caller (allocated via `allocator`).
fn writeOverrideOrConstName(
    allocator: std.mem.Allocator,
    g: ir.Global,
) FrontendError!?[]const u8 {
    return switch (g.class) {
        .override_ => blk: {
            if (g.override_id) |id| {
                break :blk try std.fmt.allocPrint(allocator, "override@id:{d}", .{id});
            }
            break :blk try std.fmt.allocPrint(allocator, "override:{s}", .{g.name});
        },
        .const_ => try std.fmt.allocPrint(allocator, "const:{s}", .{g.name}),
        else => null,
    };
}

/// Detect `let i: u32 = gid.x` / `.y` / `.z` shaped
/// initializers: `member(param_ref(N), "x"|"y"|"z")` where the
/// referenced parameter is annotated
/// `@builtin(global_invocation_id)`. Returns the member field
/// name (`"x"`, `"y"`, or `"z"`) so the caller can emit a
/// dispatch-grid `IterationAxis` with an `upper_bound` string
/// like `"dispatch.x"` that downstream residency planning
/// recognizes. Returns `null` otherwise so non-dispatch locals
/// stay out of the axes slice.
pub fn tryExtractDispatchAxisLetter(
    function: *const ir.Function,
    init_expr_opt: ?ir.ExprId,
) ?[]const u8 {
    const init_id = init_expr_opt orelse return null;

    // Unwrap a leading `.load` — single-component vector
    // swizzles like `gid.x` can be ref-category in sema, in
    // which case `lower_value_expr` wraps the member access
    // with a load before storing it in a `let`.
    var cursor = init_id;
    while (true) {
        const node = function.exprs.items[cursor];
        switch (node.data) {
            .load => |inner| cursor = inner,
            .member => break,
            else => return null,
        }
    }
    const member_node = function.exprs.items[cursor];
    const m = member_node.data.member;

    var base = m.base;
    while (true) {
        const bn = function.exprs.items[base];
        switch (bn.data) {
            .load => |inner| base = inner,
            .param_ref => |pidx| {
                if (pidx >= function.params.items.len) return null;
                const p = function.params.items[pidx];
                const io = p.io orelse return null;
                if (io.builtin != .global_invocation_id) return null;
                return m.field_name;
            },
            else => return null,
        }
    }
}

/// Detect the WGSL shape `param_struct.field` in an IR rhs
/// expression. Walks through outer `load` wrappers, then expects
/// a `member` whose base chain terminates at a `global_ref`.
/// Returns the global's index and the member's field name when the
/// pattern matches, `null` otherwise. The caller still has to
/// verify the global's `addr_space` / `class` to decide whether
/// the access is valid as a symbolic bound.
fn extractUniformFieldAccess(
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?struct { global_index: u32, field_name: []const u8 } {
    var cursor = expr_id;
    while (true) {
        const node = function.exprs.items[cursor];
        switch (node.data) {
            .load => |inner| cursor = inner,
            .member => |m| {
                var base = m.base;
                while (true) {
                    const bn = function.exprs.items[base];
                    switch (bn.data) {
                        .load => |inner| base = inner,
                        .global_ref => |gi| return .{
                            .global_index = gi,
                            .field_name = m.field_name,
                        },
                        else => return null,
                    }
                }
            },
            else => return null,
        }
    }
}

fn findGlobalBase(function: *const ir.Function, expr_id: ir.ExprId) ?u32 {
    var cursor = expr_id;
    while (true) {
        const node = function.exprs.items[cursor];
        switch (node.data) {
            .global_ref => |idx| return idx,
            .index => |idx_expr| cursor = idx_expr.base,
            .member => |m| cursor = m.base,
            .load => |inner| cursor = inner,
            else => return null,
        }
    }
}
