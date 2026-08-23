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

pub fn preparedOperation() type {
    return @import("prepared_operation.zig");
}

pub fn executionReport() type {
    return @import("execution_report.zig");
}

pub fn runtimeConfiguration() type {
    return @import("runtime_configuration.zig");
}

pub fn runtimeTypes() type {
    return @import("runtime_types.zig");
}

pub fn runtimeTelemetry() type {
    return @import("runtime_telemetry.zig");
}

pub fn identity() type {
    return @import("identity.zig");
}

pub fn errorTaxonomy() type {
    return @import("error.zig");
}

pub fn exactness() type {
    return @import("exactness.zig");
}

pub fn ownership() type {
    return @import("ownership.zig");
}

pub fn workloadProfile() type {
    return @import("workload_profile.zig");
}

pub fn specializationPolicy() type {
    return @import("specialization_policy.zig");
}

pub fn promotionReceipt() type {
    return @import("promotion_receipt.zig");
}

pub fn renderCommand() type {
    return @import("render_command.zig");
}

pub fn spatialOperation() type {
    return @import("spatial_operation.zig");
}

pub fn evidenceContract() type {
    return @import("evidence.zig");
}

pub fn evidenceObserver() type {
    return @import("evidence_observer.zig");
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
