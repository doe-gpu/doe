const parser_expr = @import("parser_expr.zig");

pub const AttrSpan = struct {
    start: u32,
    len: u32,
};

pub fn parseAttributes(self: anytype) @TypeOf(self.*).Error!AttrSpan {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peekTag() == .@"@") {
        const at_token = self.token_idx;
        self.advance();
        const name_token = self.token_idx;
        self.advance();

        var args_start: u32 = 0;
        var args_len: u32 = 0;
        if (self.peekTag() == .@"(") {
            self.advance();
            const scratch_args_top = self.scratch.items.len;

            while (self.peekTag() != .@")" and self.peekTag() != .eof) {
                const arg = try parser_expr.parseExpr(self);
                try self.scratch.append(self.allocator, arg);
                if (self.peekTag() == .@",") self.advance();
            }
            _ = try self.expect(.@")");

            const args = self.scratch.items[scratch_args_top..];
            args_start = try self.tree.addExtraSlice(args);
            args_len = @intCast(args.len);
            self.scratch.shrinkRetainingCapacity(scratch_args_top);
        }

        const attr_node = try self.tree.addNode(.{
            .tag = .attribute,
            .main_token = at_token,
            .data = .{ .lhs = name_token, .rhs = args_start | (args_len << 16) },
        });
        try self.scratch.append(self.allocator, attr_node);
    }

    const attrs = self.scratch.items[scratch_top..];
    if (attrs.len == 0) return .{ .start = 0, .len = 0 };

    const start = try self.tree.addExtraSlice(attrs);
    return .{ .start = start, .len = @intCast(attrs.len) };
}
