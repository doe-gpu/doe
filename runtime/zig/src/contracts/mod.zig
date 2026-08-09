pub fn command() type {
    return @import("command.zig");
}

pub fn capability() type {
    return @import("capability.zig");
}

pub fn execution() type {
    return @import("execution.zig");
}

pub fn compute() type {
    return @import("compute.zig");
}

pub fn semantic() type {
    return @import("semantic.zig");
}

pub fn commandMetadata() type {
    return @import("command_metadata.zig");
}

pub fn artifact() type {
    return @import("artifact.zig");
}

pub fn binding() type {
    return @import("binding.zig");
}

pub fn backend() type {
    return @import("backend.zig");
}

pub fn texture() type {
    return @import("texture.zig");
}

pub fn textureFormat() type {
    return @import("texture_format.zig");
}

pub const shaderAbi = struct {
    pub fn dispatchInfo() type {
        return @import("shader_abi/dispatch_info.zig");
    }
};

pub const numericStability = struct {
    pub fn annotation() type {
        return @import("numeric_stability/annotation.zig");
    }
};

pub const primitives = struct {
    pub fn byteScan() type {
        return @import("primitives/byte_scan.zig");
    }
};

pub const model = struct {
    pub fn commands() type {
        return @import("command.zig");
    }

    pub fn computeTypes() type {
        return @import("model/model_compute_types.zig");
    }

    pub fn profile() type {
        return @import("model/model_profile.zig");
    }
};
