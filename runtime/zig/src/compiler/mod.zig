pub fn targets() type {
    return @import("targets/mod.zig");
}

pub fn tsir() type {
    return @import("tsir/mod.zig");
}

pub fn wgsl() type {
    return @import("wgsl/mod.zig");
}

pub const wgsl_csl = struct {
    pub fn hostCompileSource() type {
        return @import("wgsl/emit/csl/emit_csl_host_compile_source.zig");
    }

    pub fn simulator() type {
        return @import("wgsl/emit/csl/emit_csl_simulator.zig");
    }

    pub fn spec() type {
        return @import("wgsl/emit/csl/csl_spec.zig");
    }
};

pub const wgsl_frontend = struct {
    pub fn lexer() type {
        return @import("wgsl/frontend/lexer.zig");
    }

    pub fn parser() type {
        return @import("wgsl/frontend/parser.zig");
    }

    pub fn sema() type {
        return @import("wgsl/frontend/sema.zig");
    }

    pub fn token() type {
        return @import("wgsl/frontend/token.zig");
    }
};

pub const wgsl_ir = struct {
    pub fn builder() type {
        return @import("wgsl/ir/ir_builder.zig");
    }

    pub fn core() type {
        return @import("wgsl/ir/ir.zig");
    }

    pub fn optimize() type {
        return @import("wgsl/ir/ir_opt_rewrite.zig");
    }

    pub fn validate() type {
        return @import("wgsl/ir/ir_validate.zig");
    }
};

pub const wgsl_emit = struct {
    pub fn hlsl() type {
        return @import("wgsl/emit/hlsl/emit_hlsl.zig");
    }

    pub fn msl() type {
        return @import("wgsl/emit/msl/emit_msl.zig");
    }

    pub fn spirv() type {
        return @import("wgsl/emit/spirv/emit_spirv.zig");
    }
};

pub const wgsl_runtime = struct {
    pub fn compile() type {
        return @import("wgsl/runtime/runtime_compile.zig");
    }

    pub fn report() type {
        return @import("wgsl/runtime/runtime_compile_report.zig");
    }
};
