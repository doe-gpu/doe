const std = @import("std");

const Declaration = struct {
    contractTokenSha256: []const u8,
    endLine: usize,
    kind: []const u8,
    literalTokenSha256: ?[]const u8,
    literalTokens: []const []const u8,
    name: ?[]const u8,
    normalizedTokenSha256: []const u8,
    public: bool,
    startLine: usize,
    switchTags: []const []const u8,
    tokenCount: usize,
};

const LiteralInventory = struct {
    digest: ?[]const u8,
    tokens: []const []const u8,
};

const FileRecord = struct {
    declarations: []const Declaration,
    parseErrorCount: usize,
    path: []const u8,
};

fn hexDigest(allocator: std.mem.Allocator, digest: [32]u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const output = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, index| {
        output[index * 2] = alphabet[byte >> 4];
        output[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return output;
}

fn isComment(tag: std.zig.Token.Tag) bool {
    return tag == .doc_comment or tag == .container_doc_comment;
}

fn normalizedTokenDigest(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    first_token: std.zig.Ast.TokenIndex,
    last_token: std.zig.Ast.TokenIndex,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var token = first_token;
    while (token <= last_token) : (token += 1) {
        const tag = tree.tokenTag(token);
        if (isComment(tag)) continue;
        hasher.update(@tagName(tag));
        hasher.update(&.{0});
        hasher.update(tree.tokenSlice(token));
        hasher.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexDigest(allocator, digest);
}

fn containsString(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn switchTags(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    first_token: std.zig.Ast.TokenIndex,
    last_token: std.zig.Ast.TokenIndex,
) ![]const []const u8 {
    var tags = std.ArrayList([]const u8).empty;
    var token = first_token;
    while (token <= last_token) : (token += 1) {
        if (tree.tokenTag(token) != .equal_angle_bracket_right) continue;
        var cursor = token;
        var scanned: usize = 0;
        while (cursor > first_token and scanned < 64) : (scanned += 1) {
            cursor -= 1;
            const tag = tree.tokenTag(cursor);
            if (tag == .l_brace or tag == .semicolon or tag == .equal_angle_bracket_right) {
                break;
            }
            if (tag == .keyword_else) {
                const value = tree.tokenSlice(cursor);
                if (!containsString(tags.items, value)) try tags.append(allocator, value);
                continue;
            }
            if (tag != .identifier or cursor == first_token) continue;
            if (tree.tokenTag(cursor - 1) != .period) continue;
            const value = tree.tokenSlice(cursor);
            if (!containsString(tags.items, value)) try tags.append(allocator, value);
        }
    }
    std.mem.sort([]const u8, tags.items, {}, lessThanString);
    return tags.toOwnedSlice(allocator);
}

fn literalInventory(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    first_token: std.zig.Ast.TokenIndex,
    last_token: std.zig.Ast.TokenIndex,
) !LiteralInventory {
    var literals = std.ArrayList([]const u8).empty;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var token = first_token;
    while (token <= last_token) : (token += 1) {
        const tag = tree.tokenTag(token);
        if (tag != .number_literal and
            tag != .string_literal and
            tag != .multiline_string_literal_line and
            tag != .char_literal)
        {
            continue;
        }
        const value = tree.tokenSlice(token);
        try literals.append(allocator, value);
        hasher.update(@tagName(tag));
        hasher.update(&.{0});
        hasher.update(value);
        hasher.update(&.{0});
    }
    const owned = try literals.toOwnedSlice(allocator);
    if (owned.len == 0) return .{ .digest = null, .tokens = owned };
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .digest = try hexDigest(allocator, digest),
        .tokens = owned,
    };
}

fn declarationKind(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) []const u8 {
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buffer, node) != null) return "function";
    if (tree.nodeTag(node) == .test_decl) return "test";
    if (tree.fullVarDecl(node)) |variable| {
        const mutability = tree.tokenSlice(variable.ast.mut_token);
        if (variable.ast.init_node.unwrap()) |initializer| {
            const initializer_token = tree.tokenSlice(tree.nodeMainToken(initializer));
            if (std.mem.eql(u8, initializer_token, "struct")) return "struct";
            if (std.mem.eql(u8, initializer_token, "union")) return "union";
            if (std.mem.eql(u8, initializer_token, "enum")) return "enum";
        }
        return if (std.mem.eql(u8, mutability, "const")) "constant" else "variable";
    }
    return @tagName(tree.nodeTag(node));
}

fn contractTokenDigest(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    declaration_first_token: std.zig.Ast.TokenIndex,
    declaration_last_token: std.zig.Ast.TokenIndex,
) ![]u8 {
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buffer, node)) |function| {
        return normalizedTokenDigest(
            allocator,
            tree,
            function.firstToken(),
            tree.lastToken(function.ast.proto_node),
        );
    }
    return normalizedTokenDigest(
        allocator,
        tree,
        declaration_first_token,
        declaration_last_token,
    );
}

fn declarationName(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) ?[]const u8 {
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buffer, node)) |function| {
        return if (function.name_token) |token| tree.tokenSlice(token) else null;
    }
    if (tree.fullVarDecl(node)) |variable| {
        return tree.tokenSlice(variable.ast.mut_token + 1);
    }
    return null;
}

fn isPublicDeclaration(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) bool {
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buffer, node)) |function| {
        return function.visib_token != null;
    }
    if (tree.fullVarDecl(node)) |variable| return variable.visib_token != null;
    return false;
}

fn parseFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) !FileRecord {
    const source = try std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        16 * 1024 * 1024,
        null,
        .of(u8),
        0,
    );
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    var declarations = std.ArrayList(Declaration).empty;
    for (tree.rootDecls()) |node| {
        const first_token = tree.firstToken(node);
        const last_token = tree.lastToken(node);
        const start_location = std.zig.findLineColumn(
            tree.source,
            tree.tokenStart(first_token),
        );
        const end_location = std.zig.findLineColumn(
            tree.source,
            tree.tokenStart(last_token) + @as(u32, @intCast(tree.tokenSlice(last_token).len)),
        );
        const literals = try literalInventory(
            allocator,
            &tree,
            first_token,
            last_token,
        );
        try declarations.append(allocator, .{
            .contractTokenSha256 = try contractTokenDigest(
                allocator,
                &tree,
                node,
                first_token,
                last_token,
            ),
            .endLine = end_location.line + 1,
            .kind = declarationKind(&tree, node),
            .literalTokenSha256 = literals.digest,
            .literalTokens = literals.tokens,
            .name = declarationName(&tree, node),
            .normalizedTokenSha256 = try normalizedTokenDigest(
                allocator,
                &tree,
                first_token,
                last_token,
            ),
            .public = isPublicDeclaration(&tree, node),
            .startLine = start_location.line + 1,
            .switchTags = try switchTags(allocator, &tree, first_token, last_token),
            .tokenCount = last_token - first_token + 1,
        });
    }
    return .{
        .declarations = try declarations.toOwnedSlice(allocator),
        .parseErrorCount = tree.errors.len,
        .path = path,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var arguments = try std.process.argsWithAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.next();
    var files = std.ArrayList(FileRecord).empty;
    while (arguments.next()) |path| {
        try files.append(allocator, try parseFile(allocator, path));
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(
        files.items,
        .{ .whitespace = .indent_2 },
        &output.writer,
    );
    try output.writer.writeByte('\n');
    try std.fs.File.stdout().writeAll(output.written());
}
