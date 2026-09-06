pub const quirk_toggle_registry_json =
    \\{"schemaVersion":1,"toggles":[{"toggle_name":"escaped\u005fname","effect":"behavioral","description":"quoted \"value\"\nnext line"}]}
;
pub const quirk_toggle_registry = [_]struct { toggle_name: []const u8, effect: []const u8, description: []const u8 }{
    .{ .toggle_name = "escaped_name", .effect = "behavioral", .description = "quoted \"value\"\nnext line" },
};
