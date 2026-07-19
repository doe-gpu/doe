pub const DEVICE_LOST_FUTURE_ID_BASE: u64 = 0xD0E1_0000_0000_0000;
const FUTURE_ID_KIND_MASK: u64 = 0xFFFF_0000_0000_0000;
const FUTURE_ID_PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;

pub fn device_lost_future_id(raw: ?*anyopaque) u64 {
    const payload = if (raw) |ptr| @intFromPtr(ptr) & FUTURE_ID_PAYLOAD_MASK else 0;
    return DEVICE_LOST_FUTURE_ID_BASE | payload;
}

pub fn is_device_lost_future_id(id: u64) bool {
    return (id & FUTURE_ID_KIND_MASK) == DEVICE_LOST_FUTURE_ID_BASE;
}
