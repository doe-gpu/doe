// SPIR-V specification constants: error types, magic numbers, and enum-like
// constant structs extracted from spirv_builder.zig for file-size discipline.

pub const EmitError = error{
    OutOfMemory,
    OutputTooLarge,
    UnsupportedConstruct,
};

pub const WORD_BYTES: usize = 4;
pub const MAGIC: u32 = 0x07230203;

pub const Capability = struct {
    pub const Shader: u32 = 1;
    // Capability.ClipDistance is 32 per Khronos; Doe previously used 5 which
    // is Linkage. Latent bug -- only hit by shaders using
    // @builtin(clip_distances), which the current compute cohort does not.
    pub const ClipDistance: u32 = 32;
    pub const Float16: u32 = 9;
    pub const SampleRateShading: u32 = 35;
    pub const StorageBuffer16BitAccess: u32 = 4433;
    pub const GroupNonUniform: u32 = 61;
    pub const GroupNonUniformArithmetic: u32 = 63;
    pub const GroupNonUniformShuffle: u32 = 65;
    pub const GroupNonUniformVote: u32 = 62;
    pub const GroupNonUniformBallot: u32 = 64;
    pub const StorageImageExtendedFormats: u32 = 49;
    pub const ImageQuery: u32 = 50;
    pub const DerivativeControl: u32 = 51;
};

pub const AddressingModel = struct {
    pub const Logical: u32 = 0;
};
pub const MemoryModel = struct {
    pub const GLSL450: u32 = 1;
};
pub const Dim = struct {
    pub const _1D: u32 = 0;
    pub const _2D: u32 = 1;
    pub const _3D: u32 = 2;
    pub const Cube: u32 = 3;
};

pub const ImageFormat = struct {
    // Values from Khronos SPIR-V unified spec section "Image Format". Prior
    // int/uint entries (Rgba32i through Rg32ui) were shifted up by ~15, all
    // out of range in the spec. Latent: compute cohort does not use storage
    // images; any shader declaring texture_storage_Nd<rXsint|rXuint> would
    // have emitted invalid OpTypeImage. Cross-verified via Tint emission
    // for texture_storage_2d<r32sint, write> (format=24 in Tint).
    pub const Unknown: u32 = 0;
    pub const Rgba32f: u32 = 1;
    pub const Rgba16f: u32 = 2;
    pub const R32f: u32 = 3;
    pub const Rgba8: u32 = 4;
    pub const Rgba8Snorm: u32 = 5;
    pub const Rg32f: u32 = 6;
    pub const Rg16f: u32 = 7;
    pub const R16f: u32 = 9;
    pub const Rgba16: u32 = 10;
    pub const Rgba32i: u32 = 21;
    pub const Rgba16i: u32 = 22;
    pub const Rgba8i: u32 = 23;
    pub const R32i: u32 = 24;
    pub const Rg32i: u32 = 25;
    pub const Rgba32ui: u32 = 30;
    pub const Rgba16ui: u32 = 31;
    pub const Rgba8ui: u32 = 32;
    pub const R32ui: u32 = 33;
    pub const Rg32ui: u32 = 35;
};

pub const ImageOperandsMask = struct {
    // Canonical SPIR-V ImageOperands mask values per spirv.h. Previously Offset
    // held 0x04 (actually Grad), Grad held 0x08 (actually ConstOffset), and
    // ConstOffset held 0x10 (actually Offset) — a three-way permutation. Latent
    // in the compute-only cohort (storage images do not emit these operands);
    // any texture-sampling shader using OpImageSampleImplicitLod with explicit
    // gradient, constant-offset, or runtime-offset operands would have written
    // the wrong operand bitset into the generated SPIR-V word.
    pub const Bias: u32 = 0x00000001;
    pub const Lod: u32 = 0x00000002;
    pub const Grad: u32 = 0x00000004;
    pub const ConstOffset: u32 = 0x00000008;
    pub const Offset: u32 = 0x00000010;
    pub const Sample: u32 = 0x00000040;
};

pub const ExecutionModel = struct {
    pub const Vertex: u32 = 0;
    pub const Fragment: u32 = 4;
    pub const GLCompute: u32 = 5;
};

pub const ExecutionMode = struct {
    pub const OriginUpperLeft: u32 = 7;
    pub const DepthReplacing: u32 = 12;
    pub const LocalSize: u32 = 17;
};

pub const Scope = struct {
    pub const CrossDevice: u32 = 0;
    pub const Device: u32 = 1;
    pub const Workgroup: u32 = 2;
    pub const Subgroup: u32 = 3;
    pub const Invocation: u32 = 4;
};

pub const GroupOperation = struct {
    pub const Reduce: u32 = 0;
    pub const InclusiveScan: u32 = 1;
    pub const ExclusiveScan: u32 = 2;
};

pub const MemorySemantics = struct {
    pub const None: u32 = 0x00000000;
    pub const Acquire: u32 = 0x00000002;
    pub const Release: u32 = 0x00000004;
    pub const AcquireRelease: u32 = 0x00000008;
    pub const SequentiallyConsistent: u32 = 0x00000010;
    pub const UniformMemory: u32 = 0x00000040;
    pub const WorkgroupMemory: u32 = 0x00000100;
    pub const ImageMemory: u32 = 0x00000800;
};

pub const StorageClass = struct {
    pub const UniformConstant: u32 = 0;
    pub const Input: u32 = 1;
    pub const Uniform: u32 = 2;
    pub const Output: u32 = 3;
    pub const Workgroup: u32 = 4;
    pub const Private: u32 = 6;
    pub const Function: u32 = 7;
    pub const StorageBuffer: u32 = 12;
};

pub const Decoration = struct {
    // Previously had Invariant=0 (actually RelaxedPrecision) and Index=31
    // (actually Component). Latent bugs hit by @invariant-decorated builtins
    // and @blend_src dual-source-blend locations on vertex/fragment stages.
    pub const Block: u32 = 2;
    pub const ColMajor: u32 = 5;
    pub const ArrayStride: u32 = 6;
    pub const MatrixStride: u32 = 7;
    pub const BuiltIn: u32 = 11;
    pub const NoPerspective: u32 = 13;
    pub const Flat: u32 = 14;
    pub const Centroid: u32 = 16;
    pub const Sample: u32 = 17;
    pub const Invariant: u32 = 18;
    pub const NonWritable: u32 = 24;
    pub const NonReadable: u32 = 25;
    pub const Location: u32 = 30;
    pub const Index: u32 = 32;
    pub const Binding: u32 = 33;
    pub const DescriptorSet: u32 = 34;
    pub const Offset: u32 = 35;
};

pub const Builtin = struct {
    // Values from the Khronos SPIR-V unified spec section "Builtin". Prior
    // entries for ClipDistance, NumWorkgroups, LocalInvocationId, and
    // LocalInvocationIndex were off by one; 2D/3D compute workloads that
    // read `local_invocation_id.y` / `.z` were silently getting zero on
    // RADV because the decoration landed on LocalInvocationIndex (a scalar).
    pub const Position: u32 = 0;
    pub const ClipDistance: u32 = 3;
    pub const PrimitiveId: u32 = 7;
    pub const FragCoord: u32 = 15;
    pub const FrontFacing: u32 = 17;
    pub const SampleIndex: u32 = 18;
    pub const SampleMask: u32 = 20;
    pub const FragDepth: u32 = 22;
    pub const NumWorkgroups: u32 = 24;
    pub const WorkgroupId: u32 = 26;
    pub const LocalInvocationId: u32 = 27;
    pub const GlobalInvocationId: u32 = 28;
    pub const LocalInvocationIndex: u32 = 29;
    pub const SubgroupSize: u32 = 36;
    pub const SubgroupLocalInvocationId: u32 = 41;
    pub const VertexIndex: u32 = 42;
    pub const InstanceIndex: u32 = 43;
};

pub const FunctionControl = struct {
    pub const None: u32 = 0;
};

pub const SelectionControl = struct {
    pub const None: u32 = 0;
};

pub const LoopControl = struct {
    pub const None: u32 = 0;
};

pub const Opcode = struct {
    pub const Name: u16 = 5;
    pub const ExtInstImport: u16 = 11;
    pub const ExtInst: u16 = 12;
    pub const EntryPoint: u16 = 15;
    pub const ExecutionMode: u16 = 16;
    pub const Capability: u16 = 17;
    pub const TypeVoid: u16 = 19;
    pub const TypeBool: u16 = 20;
    pub const TypeInt: u16 = 21;
    pub const TypeFloat: u16 = 22;
    pub const TypeVector: u16 = 23;
    pub const TypeMatrix: u16 = 24;
    pub const TypeImage: u16 = 25;
    pub const TypeArray: u16 = 28;
    pub const TypeRuntimeArray: u16 = 29;
    pub const TypeStruct: u16 = 30;
    pub const TypePointer: u16 = 32;
    pub const TypeFunction: u16 = 33;
    pub const ConstantTrue: u16 = 41;
    pub const ConstantFalse: u16 = 42;
    pub const Constant: u16 = 43;
    pub const ConstantComposite: u16 = 44;
    pub const Function: u16 = 54;
    pub const FunctionParameter: u16 = 55;
    pub const FunctionEnd: u16 = 56;
    pub const FunctionCall: u16 = 57;
    pub const Variable: u16 = 59;
    pub const Load: u16 = 61;
    pub const Store: u16 = 62;
    pub const AccessChain: u16 = 65;
    pub const Decorate: u16 = 71;
    pub const MemberDecorate: u16 = 72;
    pub const VectorExtractDynamic: u16 = 77;
    pub const CompositeConstruct: u16 = 80;
    pub const CompositeExtract: u16 = 81;
    pub const SampledImage: u16 = 86;
    pub const ImageSampleImplicitLod: u16 = 87;
    pub const ImageSampleExplicitLod: u16 = 88;
    pub const ImageSampleDrefImplicitLod: u16 = 89;
    pub const ImageSampleDrefExplicitLod: u16 = 90;
    pub const ImageFetch: u16 = 95;
    pub const ImageGather: u16 = 96;
    pub const ImageDrefGather: u16 = 97;
    pub const ImageWrite: u16 = 99;
    pub const ImageQuerySizeLod: u16 = 103;
    pub const ImageQuerySize: u16 = 104;
    pub const ImageQueryLevels: u16 = 106;
    pub const ConvertFToU: u16 = 109;
    pub const ConvertFToS: u16 = 110;
    pub const ConvertSToF: u16 = 111;
    pub const ConvertUToF: u16 = 112;
    pub const FConvert: u16 = 115;
    pub const Transpose: u16 = 84;
    pub const SNegate: u16 = 126;
    pub const Bitcast: u16 = 124;
    pub const FNegate: u16 = 127;
    pub const IAdd: u16 = 128;
    pub const FAdd: u16 = 129;
    pub const ISub: u16 = 130;
    pub const FSub: u16 = 131;
    pub const IMul: u16 = 132;
    pub const FMul: u16 = 133;
    pub const UDiv: u16 = 134;
    pub const SDiv: u16 = 135;
    pub const FDiv: u16 = 136;
    pub const UMod: u16 = 137;
    pub const SRem: u16 = 138;
    pub const FRem: u16 = 140;
    pub const VectorTimesScalar: u16 = 142;
    pub const MatrixTimesScalar: u16 = 143;
    pub const VectorTimesMatrix: u16 = 144;
    pub const MatrixTimesVector: u16 = 145;
    pub const MatrixTimesMatrix: u16 = 146;
    pub const Dot: u16 = 148;
    pub const Any: u16 = 154;
    pub const All: u16 = 155;
    pub const ArrayLength: u16 = 68;
    pub const LogicalEqual: u16 = 164;
    pub const LogicalNotEqual: u16 = 165;
    pub const LogicalOr: u16 = 166;
    pub const LogicalAnd: u16 = 167;
    pub const LogicalNot: u16 = 168;
    pub const Select: u16 = 169;
    pub const IEqual: u16 = 170;
    pub const INotEqual: u16 = 171;
    pub const UGreaterThan: u16 = 172;
    pub const SGreaterThan: u16 = 173;
    pub const UGreaterThanEqual: u16 = 174;
    pub const SGreaterThanEqual: u16 = 175;
    pub const ULessThan: u16 = 176;
    pub const SLessThan: u16 = 177;
    pub const ULessThanEqual: u16 = 178;
    pub const SLessThanEqual: u16 = 179;
    pub const FOrdEqual: u16 = 180;
    pub const FOrdNotEqual: u16 = 182;
    pub const FOrdLessThan: u16 = 184;
    pub const FOrdGreaterThan: u16 = 186;
    pub const FOrdLessThanEqual: u16 = 188;
    pub const FOrdGreaterThanEqual: u16 = 190;
    pub const ShiftRightLogical: u16 = 194;
    pub const ShiftRightArithmetic: u16 = 195;
    pub const ShiftLeftLogical: u16 = 196;
    pub const BitwiseOr: u16 = 197;
    pub const BitwiseXor: u16 = 198;
    pub const BitwiseAnd: u16 = 199;
    pub const Not: u16 = 200;
    pub const BitFieldInsert: u16 = 201;
    pub const BitFieldSExtract: u16 = 202;
    pub const BitFieldUExtract: u16 = 203;
    pub const BitReverse: u16 = 204;
    pub const BitCount: u16 = 205;
    pub const DPdx: u16 = 207;
    pub const DPdy: u16 = 208;
    pub const Fwidth: u16 = 209;
    pub const DPdxFine: u16 = 210;
    pub const DPdyFine: u16 = 211;
    pub const FwidthFine: u16 = 212;
    pub const DPdxCoarse: u16 = 213;
    pub const DPdyCoarse: u16 = 214;
    pub const FwidthCoarse: u16 = 215;
    pub const ControlBarrier: u16 = 224;
    pub const MemoryBarrier: u16 = 225;
    pub const AtomicLoad: u16 = 227;
    pub const AtomicStore: u16 = 228;
    pub const AtomicExchange: u16 = 229;
    pub const AtomicCompareExchange: u16 = 230;
    pub const AtomicIAdd: u16 = 234;
    pub const AtomicISub: u16 = 235;
    pub const AtomicSMin: u16 = 236;
    pub const AtomicUMin: u16 = 237;
    pub const AtomicSMax: u16 = 238;
    pub const AtomicUMax: u16 = 239;
    pub const AtomicAnd: u16 = 240;
    pub const AtomicOr: u16 = 241;
    pub const AtomicXor: u16 = 242;
    pub const GroupNonUniformAll: u16 = 334;
    pub const GroupNonUniformAny: u16 = 335;
    pub const GroupNonUniformBallot: u16 = 339;
    pub const GroupNonUniformBroadcast: u16 = 337;
    pub const GroupNonUniformElect: u16 = 333;
    pub const GroupNonUniformBroadcastFirst: u16 = 338;
    pub const GroupNonUniformShuffle: u16 = 345;
    pub const GroupNonUniformShuffleXor: u16 = 346;
    pub const GroupNonUniformShuffleUp: u16 = 347;
    pub const GroupNonUniformShuffleDown: u16 = 348;
    pub const GroupNonUniformIAdd: u16 = 349;
    pub const GroupNonUniformFAdd: u16 = 350;
    pub const GroupNonUniformSMin: u16 = 353;
    pub const GroupNonUniformUMin: u16 = 354;
    pub const GroupNonUniformFMin: u16 = 355;
    pub const GroupNonUniformIMul: u16 = 351;
    pub const GroupNonUniformFMul: u16 = 352;
    pub const GroupNonUniformSMax: u16 = 356;
    pub const GroupNonUniformUMax: u16 = 357;
    pub const GroupNonUniformFMax: u16 = 358;
    pub const GroupNonUniformBitwiseAnd: u16 = 359;
    pub const GroupNonUniformBitwiseOr: u16 = 360;
    pub const GroupNonUniformBitwiseXor: u16 = 361;
    pub const Label: u16 = 248;
    pub const Branch: u16 = 249;
    pub const BranchConditional: u16 = 250;
    pub const Switch: u16 = 251;
    pub const Kill: u16 = 252;
    pub const Return: u16 = 253;
    pub const ReturnValue: u16 = 254;
    pub const Unreachable: u16 = 255;
    pub const FunctionCallResult: u16 = 57;
    pub const LoopMerge: u16 = 246;
    pub const SelectionMerge: u16 = 247;
    pub const OpMemoryModel: u16 = 14;
};
