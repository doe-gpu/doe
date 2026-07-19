const std = @import("std");
const ast_mod = @import("ast.zig");
const ir = @import("../ir/ir.zig");
const token_mod = @import("token.zig");

const Ast = ast_mod.Ast;

pub const AnalyzeError = error{
    OutOfMemory,
    DuplicateSymbol,
    InvalidAttribute,
    InvalidType,
    InvalidWgsl,
    TypeMismatch,
    UnknownIdentifier,
    UnknownType,
    UnsupportedConstruct,
    UnsupportedBuiltin,
};

pub const SymbolRef = union(enum) {
    none,
    global: u32,
    function: u32,
    param: u32,
    local: u32,
};

pub const NodeInfo = struct {
    ty: ir.TypeId = ir.INVALID_TYPE,
    symbol: SymbolRef = .none,
    category: ir.ExprCategory = .value,
};

pub const AliasInfo = struct {
    name: []const u8,
    ty: ir.TypeId,

    fn deinit(self: *AliasInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const StructFieldInfo = struct {
    name: []const u8,
    ty: ir.TypeId,
    io: ?ir.IoAttr = null,

    fn deinit(self: *StructFieldInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const StructInfo = struct {
    name: []const u8,
    struct_id: ir.StructId,
    ty: ir.TypeId,
    fields: std.ArrayListUnmanaged(StructFieldInfo) = .{},

    fn deinit(self: *StructInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.fields.items) |*field| field.deinit(allocator);
        self.fields.deinit(allocator);
    }
};

pub const GlobalInfo = struct {
    name: []const u8,
    node_idx: u32,
    ty: ir.TypeId,
    class: ir.GlobalClass,
    addr_space: ?ir.AddressSpace = null,
    access: ?ir.AccessMode = null,
    binding: ?ir.BindingPoint = null,
    io: ?ir.IoAttr = null,
    override_id: ?u32 = null,

    fn deinit(self: *GlobalInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const ParamInfo = struct {
    name: []const u8,
    ty: ir.TypeId,
    io: ?ir.IoAttr = null,

    fn deinit(self: *ParamInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const LocalInfo = struct {
    name: []const u8,
    ty: ir.TypeId,
    mutable: bool,

    fn deinit(self: *LocalInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const FunctionInfo = struct {
    name: []const u8,
    node_idx: u32,
    return_type: ir.TypeId,
    return_io: ?ir.IoAttr = null,
    stage: ?ir.ShaderStage = null,
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
    params: std.ArrayListUnmanaged(ParamInfo) = .{},
    locals: std.ArrayListUnmanaged(LocalInfo) = .{},

    fn deinit(self: *FunctionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.params.items) |*param| param.deinit(allocator);
        self.params.deinit(allocator);
        for (self.locals.items) |*local| local.deinit(allocator);
        self.locals.deinit(allocator);
    }
};

pub const SemanticModule = struct {
    allocator: std.mem.Allocator,
    tree: *const Ast,
    types: ir.TypeStore,
    node_info: std.ArrayListUnmanaged(NodeInfo) = .{},
    globals: std.ArrayListUnmanaged(GlobalInfo) = .{},
    functions: std.ArrayListUnmanaged(FunctionInfo) = .{},
    structs: std.ArrayListUnmanaged(StructInfo) = .{},
    aliases: std.ArrayListUnmanaged(AliasInfo) = .{},
    global_map: std.StringHashMapUnmanaged(u32) = .{},
    function_map: std.StringHashMapUnmanaged(u32) = .{},
    struct_map: std.StringHashMapUnmanaged(u32) = .{},
    alias_map: std.StringHashMapUnmanaged(u32) = .{},
    void_type: ir.TypeId = ir.INVALID_TYPE,
    bool_type: ir.TypeId = ir.INVALID_TYPE,
    abstract_int_type: ir.TypeId = ir.INVALID_TYPE,
    abstract_float_type: ir.TypeId = ir.INVALID_TYPE,
    i32_type: ir.TypeId = ir.INVALID_TYPE,
    u32_type: ir.TypeId = ir.INVALID_TYPE,
    f32_type: ir.TypeId = ir.INVALID_TYPE,
    f16_type: ir.TypeId = ir.INVALID_TYPE,
    sampler_type: ir.TypeId = ir.INVALID_TYPE,
    sampler_comparison_type: ir.TypeId = ir.INVALID_TYPE,

    pub fn deinit(self: *SemanticModule) void {
        self.node_info.deinit(self.allocator);
        for (self.globals.items) |*global| global.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        for (self.functions.items) |*function| function.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        for (self.structs.items) |*struct_info| struct_info.deinit(self.allocator);
        self.structs.deinit(self.allocator);
        for (self.aliases.items) |*alias_info| alias_info.deinit(self.allocator);
        self.aliases.deinit(self.allocator);
        self.global_map.deinit(self.allocator);
        self.function_map.deinit(self.allocator);
        self.struct_map.deinit(self.allocator);
        self.alias_map.deinit(self.allocator);
        self.types.deinit();
    }

    pub fn nodeType(self: *const SemanticModule, node_idx: u32) ir.TypeId {
        return self.node_info.items[node_idx].ty;
    }

    pub fn nodeSymbol(self: *const SemanticModule, node_idx: u32) SymbolRef {
        return self.node_info.items[node_idx].symbol;
    }

    pub fn nodeCategory(self: *const SemanticModule, node_idx: u32) ir.ExprCategory {
        return self.node_info.items[node_idx].category;
    }

    pub fn tryResolveNamedType(self: *const SemanticModule, name: []const u8) ?ir.TypeId {
        const types = @constCast(&self.types);
        if (self.struct_map.get(name)) |struct_id| return self.structs.items[struct_id].ty;
        if (self.alias_map.get(name)) |alias_index| {
            const ty = self.aliases.items[alias_index].ty;
            if (ty != ir.INVALID_TYPE) return ty;
        }
        return switch (token_mod.lookupIdent(name)) {
            .kw_vec2f => types.intern(.{ .vector = .{ .elem = self.f32_type, .len = 2 } }) catch null,
            .kw_vec3f => types.intern(.{ .vector = .{ .elem = self.f32_type, .len = 3 } }) catch null,
            .kw_vec4f => types.intern(.{ .vector = .{ .elem = self.f32_type, .len = 4 } }) catch null,
            .kw_vec2u => types.intern(.{ .vector = .{ .elem = self.u32_type, .len = 2 } }) catch null,
            .kw_vec3u => types.intern(.{ .vector = .{ .elem = self.u32_type, .len = 3 } }) catch null,
            .kw_vec4u => types.intern(.{ .vector = .{ .elem = self.u32_type, .len = 4 } }) catch null,
            .kw_vec2i => types.intern(.{ .vector = .{ .elem = self.i32_type, .len = 2 } }) catch null,
            .kw_vec3i => types.intern(.{ .vector = .{ .elem = self.i32_type, .len = 3 } }) catch null,
            .kw_vec4i => types.intern(.{ .vector = .{ .elem = self.i32_type, .len = 4 } }) catch null,
            .kw_vec2h => types.intern(.{ .vector = .{ .elem = self.f16_type, .len = 2 } }) catch null,
            .kw_vec3h => types.intern(.{ .vector = .{ .elem = self.f16_type, .len = 3 } }) catch null,
            .kw_vec4h => types.intern(.{ .vector = .{ .elem = self.f16_type, .len = 4 } }) catch null,
            .kw_mat2x2f => types.intern(.{ .matrix = .{ .elem = self.f32_type, .columns = 2, .rows = 2 } }) catch null,
            .kw_mat3x3f => types.intern(.{ .matrix = .{ .elem = self.f32_type, .columns = 3, .rows = 3 } }) catch null,
            .kw_mat4x4f => types.intern(.{ .matrix = .{ .elem = self.f32_type, .columns = 4, .rows = 4 } }) catch null,
            .kw_mat2x2h => types.intern(.{ .matrix = .{ .elem = self.f16_type, .columns = 2, .rows = 2 } }) catch null,
            .kw_mat3x3h => types.intern(.{ .matrix = .{ .elem = self.f16_type, .columns = 3, .rows = 3 } }) catch null,
            .kw_mat4x4h => types.intern(.{ .matrix = .{ .elem = self.f16_type, .columns = 4, .rows = 4 } }) catch null,
            else => null,
        };
    }
};
