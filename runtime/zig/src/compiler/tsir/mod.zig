// TSIR public module surface.
//
// Downstream callers (frontend, residency/collective passes, emitters,
// parity CLI) depend only on `tsir.Semantic`, `tsir.Realization`,
// `tsir.Digests`, the rejection taxonomy, and the reference interpreter
// entry point. Nothing else is public.

pub const schema = @import("schema.zig");
pub const digest = @import("digest.zig");
pub const reference = @import("reference_interpreter.zig");
pub const frontend = @import("frontend.zig");
pub const planner = @import("planner.zig");
pub const emit_kernel_body = @import("emit_kernel_body.zig");
pub const emit_csl = @import("emit_csl.zig");
pub const emit_dxil = @import("emit_dxil.zig");
pub const emit_msl = @import("emit_msl.zig");
pub const emit_spir_v = @import("emit_spir_v.zig");
pub const emit_webgpu = @import("emit_webgpu.zig");

pub const CONTRACT_VERSION = schema.CONTRACT_VERSION;

pub const ExactnessClass = schema.ExactnessClass;
pub const AlgorithmExactInvariant = schema.AlgorithmExactInvariant;
pub const Exactness = schema.Exactness;
pub const RejectionReason = schema.RejectionReason;
pub const RejectionEntry = schema.RejectionEntry;
pub const KernelFamilyHint = schema.KernelFamilyHint;
pub const ScalarKind = schema.ScalarKind;
pub const ReductionAssociativity = schema.ReductionAssociativity;
pub const NanInfPolicy = schema.NanInfPolicy;
pub const NumericalContract = schema.NumericalContract;
pub const ReductionOp = schema.ReductionOp;
pub const ReductionRealizationNode = schema.ReductionRealizationNode;
pub const SemanticBodyOp = schema.SemanticBodyOp;
pub const SemanticBindingRole = schema.SemanticBindingRole;
pub const SemanticAxisRole = schema.SemanticAxisRole;
pub const SemanticBodyBinding = schema.SemanticBodyBinding;
pub const SemanticBodyAxis = schema.SemanticBodyAxis;
pub const IterationAxis = schema.IterationAxis;
pub const BufferBinding = schema.BufferBinding;
pub const SemanticFunction = schema.SemanticFunction;
pub const RmsNormFormula = schema.RmsNormFormula;
pub const RmsNormReductionTarget = schema.RmsNormReductionTarget;
pub const RmsNormEpsilonSource = schema.RmsNormEpsilonSource;
pub const RmsNormEpsilon = schema.RmsNormEpsilon;
pub const RmsNormBody = schema.RmsNormBody;
pub const SemanticBody = schema.SemanticBody;
pub const CollectiveKind = schema.CollectiveKind;
pub const ReductionTreeShape = schema.ReductionTreeShape;
pub const ResidencyClass = schema.ResidencyClass;
pub const Semantic = schema.Semantic;
pub const Realization = schema.Realization;
pub const Digests = schema.Digests;
pub const ManifestLoweringEntry = schema.ManifestLoweringEntry;
