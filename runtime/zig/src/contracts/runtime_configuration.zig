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

/// Construction-time policy for a provider-owned mutable pipeline cache.
///
/// The directory is borrowed by the contract caller and must be copied by a
/// provider that retains it. An empty directory preserves provider-specific
/// environment/default resolution; it never aliases the immutable kernel
/// root.
pub const PipelineCacheConfiguration = struct {
    enabled: bool = true,
    directory: []const u8 = "",
};
