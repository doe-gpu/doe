const std = @import("std");
const backend_ids = @import("../../src/contracts/backend.zig");

test "backend id names are stable" {
    try std.testing.expectEqualStrings("dawn_delegate", backend_ids.backend_id_name(.dawn_delegate));
    try std.testing.expectEqualStrings("doe_metal", backend_ids.backend_id_name(.doe_metal));
    try std.testing.expectEqualStrings("doe_vulkan", backend_ids.backend_id_name(.doe_vulkan));
    try std.testing.expectEqualStrings("doe_d3d12", backend_ids.backend_id_name(.doe_d3d12));
}
