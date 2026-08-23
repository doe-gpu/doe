//! Backend-neutral runtime configuration values used by narrow control ports.

pub const UploadBufferUsageMode = enum {
    copy_dst_copy_src,
    copy_dst,
};

pub const QueueWaitMode = enum {
    process_events,
    wait_any,
};

pub const QueueSyncMode = enum {
    per_command,
    deferred,
};

pub const GpuTimestampMode = enum {
    auto,
    off,
    require,
};
