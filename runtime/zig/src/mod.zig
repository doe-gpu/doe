pub const backend = struct {
    pub fn runtime() type {
        return @import("backend/backend_runtime.zig");
    }

    pub fn runtimeTypes() type {
        return @import("backend/runtime_types.zig");
    }
};

pub const cli = struct {
    pub fn doePlanExecutor() type {
        return @import("cli/doe_plan_executor_cli.zig");
    }

    pub fn moduleRunner() type {
        return @import("cli/module_runner_cli.zig");
    }

    pub fn runtime() type {
        return @import("cli/runtime_cli.zig");
    }
};

pub const compiler = struct {
    pub fn targets() type {
        return @import("compiler/targets/mod.zig");
    }

    pub fn tsir() type {
        return @import("compiler/tsir/mod.zig");
    }

    pub fn wgsl() type {
        return @import("compiler/wgsl/mod.zig");
    }

    pub const wgsl_csl = struct {
        pub fn hostCompileSource() type {
            return @import("compiler/wgsl/emit/csl/emit_csl_host_compile_source.zig");
        }

        pub fn simulator() type {
            return @import("compiler/wgsl/emit/csl/emit_csl_simulator.zig");
        }

        pub fn spec() type {
            return @import("compiler/wgsl/emit/csl/csl_spec.zig");
        }
    };

    pub const wgsl_frontend = struct {
        pub fn lexer() type {
            return @import("compiler/wgsl/frontend/lexer.zig");
        }

        pub fn parser() type {
            return @import("compiler/wgsl/frontend/parser.zig");
        }

        pub fn sema() type {
            return @import("compiler/wgsl/frontend/sema.zig");
        }

        pub fn token() type {
            return @import("compiler/wgsl/frontend/token.zig");
        }
    };

    pub const wgsl_ir = struct {
        pub fn builder() type {
            return @import("compiler/wgsl/ir/ir_builder.zig");
        }

        pub fn core() type {
            return @import("compiler/wgsl/ir/ir.zig");
        }

        pub fn optimize() type {
            return @import("compiler/wgsl/ir/ir_opt_rewrite.zig");
        }

        pub fn validate() type {
            return @import("compiler/wgsl/ir/ir_validate.zig");
        }
    };

    pub const wgsl_emit = struct {
        pub fn hlsl() type {
            return @import("compiler/wgsl/emit/hlsl/emit_hlsl.zig");
        }

        pub fn msl() type {
            return @import("compiler/wgsl/emit/msl/emit_msl.zig");
        }

        pub fn spirv() type {
            return @import("compiler/wgsl/emit/spirv/emit_spirv.zig");
        }
    };

    pub const wgsl_runtime = struct {
        pub fn compile() type {
            return @import("compiler/wgsl/runtime/runtime_compile.zig");
        }

        pub fn report() type {
            return @import("compiler/wgsl/runtime/runtime_compile_report.zig");
        }
    };
};

pub const contracts = struct {
    pub const model = struct {
        pub fn commands() type {
            return @import("contracts/model/model_commands.zig");
        }

        pub fn computeTypes() type {
            return @import("contracts/model/model_compute_types.zig");
        }

        pub fn profile() type {
            return @import("contracts/model/model_profile.zig");
        }
    };
};

pub fn dropin() type {
    return @import("dropin/wgpu_dropin_lib.zig");
}

pub const plan = struct {
    pub fn doeExecutor() type {
        return @import("plan/doe_plan_executor.zig");
    }

    pub fn webgpuCli() type {
        return @import("plan/webgpu_plan_executor_cli.zig");
    }

    pub fn webgpuExecutor() type {
        return @import("plan/webgpu_plan_executor.zig");
    }
};

pub const runtime = struct {
    pub fn execution() type {
        return @import("runtime/execution.zig");
    }

    pub const simd = struct {
        pub fn byteScan() type {
            return @import("runtime/simd/byte_scan.zig");
        }

        pub fn f32Ops() type {
            return @import("runtime/simd/f32_ops.zig");
        }
    };

    pub fn traceText() type {
        return @import("runtime/trace/trace_text.zig");
    }
};

pub const verification = struct {
    pub fn leanProof() type {
        return @import("verification/lean_proof.zig");
    }
};
