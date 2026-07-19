// DXIL specification constants: LLVM bitcode IDs, DXIL opcodes, DXBC container
// FourCC codes, and shader model metadata values. Extracted for file-size
// discipline and single-source-of-truth for all DXIL magic numbers.

pub const EmitError = error{
    OutOfMemory,
    OutputTooLarge,
    UnsupportedConstruct,
    InvalidIr,
    UnsupportedBuiltin,
};

// -- LLVM bitcode stream encoding constants --

pub const BITCODE_MAGIC: u32 = 0x4243_C0DE;
pub const LLVM_IR_MAGIC: [4]u8 = .{ 'B', 'C', 0xC0, 0xDE };

pub const BlockId = struct {
    pub const MODULE: u32 = 8;
    pub const PARAMATTR: u32 = 9;
    pub const PARAMATTR_GROUP: u32 = 10;
    pub const CONSTANTS: u32 = 11;
    pub const FUNCTION: u32 = 12;
    pub const VALUE_SYMTAB: u32 = 14;
    pub const METADATA: u32 = 15;
    pub const METADATA_ATTACHMENT: u32 = 16;
    pub const TYPE: u32 = 17;
    pub const STRTAB: u32 = 23;
};

pub const AbbrevId = struct {
    pub const END_BLOCK: u32 = 0;
    pub const ENTER_SUBBLOCK: u32 = 1;
    pub const DEFINE_ABBREV: u32 = 2;
    pub const UNABBREV_RECORD: u32 = 3;
};

pub const ModuleCode = struct {
    pub const VERSION: u32 = 1;
    pub const TRIPLE: u32 = 2;
    pub const DATALAYOUT: u32 = 3;
    pub const FUNCTION: u32 = 8;
    pub const GLOBALVAR: u32 = 7;
};

pub const TypeCode = struct {
    pub const NUMENTRY: u32 = 1;
    pub const VOID: u32 = 2;
    pub const FLOAT: u32 = 3;
    pub const DOUBLE: u32 = 4;
    pub const INTEGER: u32 = 7;
    pub const POINTER: u32 = 8;
    pub const FUNCTION: u32 = 21;
    pub const STRUCT_NAMED: u32 = 20;
    pub const STRUCT_ANON: u32 = 18;
    pub const ARRAY: u32 = 11;
    pub const VECTOR: u32 = 12;
    pub const HALF: u32 = 10;
    pub const METADATA: u32 = 16;
    pub const LABEL: u32 = 5;
};

pub const ConstantCode = struct {
    pub const SETTYPE: u32 = 1;
    pub const NULL: u32 = 2;
    pub const UNDEF: u32 = 3;
    pub const INTEGER: u32 = 4;
    pub const FLOAT: u32 = 6;
    pub const AGGREGATE: u32 = 7;
    pub const STRING: u32 = 8;
    pub const CE_GEP: u32 = 12;
};

pub const FunctionCode = struct {
    pub const DECLAREBLOCKS: u32 = 1;
    pub const INST_BINOP: u32 = 2;
    pub const INST_CAST: u32 = 3;
    pub const INST_RET: u32 = 10;
    pub const INST_BR: u32 = 11;
    pub const INST_SWITCH: u32 = 12;
    pub const INST_CALL: u32 = 34;
    pub const INST_GEP: u32 = 43;
    pub const INST_LOAD: u32 = 20;
    pub const INST_STORE: u32 = 24;
    pub const INST_ALLOCA: u32 = 19;
    pub const INST_PHI: u32 = 16;
    pub const INST_CMP: u32 = 28;
    pub const INST_EXTRACTVAL: u32 = 26;
    pub const INST_INSERTVAL: u32 = 27;
};

pub const MetadataCode = struct {
    pub const STRING: u32 = 1;
    pub const VALUE: u32 = 2;
    pub const NODE: u32 = 3;
    pub const NAME: u32 = 4;
    pub const NAMED_NODE: u32 = 10;
    pub const KIND: u32 = 6;
};

pub const ValueSymtabCode = struct {
    pub const ENTRY: u32 = 1;
    pub const BBENTRY: u32 = 2;
};

// -- LLVM binary operations --

pub const BinOp = struct {
    pub const ADD: u32 = 0;
    pub const SUB: u32 = 1;
    pub const MUL: u32 = 2;
    pub const UDIV: u32 = 3;
    pub const SDIV: u32 = 4;
    pub const UREM: u32 = 5;
    pub const SREM: u32 = 6;
    pub const SHL: u32 = 7;
    pub const LSHR: u32 = 8;
    pub const ASHR: u32 = 9;
    pub const AND: u32 = 10;
    pub const OR: u32 = 11;
    pub const XOR: u32 = 12;
    pub const FADD: u32 = 0;
    pub const FSUB: u32 = 1;
    pub const FMUL: u32 = 2;
    pub const FDIV: u32 = 3;
    pub const FREM: u32 = 4;
};

pub const CastOp = struct {
    pub const TRUNC: u32 = 0;
    pub const ZEXT: u32 = 1;
    pub const SEXT: u32 = 2;
    pub const FPTOUI: u32 = 3;
    pub const FPTOSI: u32 = 4;
    pub const UITOFP: u32 = 5;
    pub const SITOFP: u32 = 6;
    pub const FPTRUNC: u32 = 7;
    pub const FPEXT: u32 = 8;
    pub const BITCAST: u32 = 11;
};

pub const CmpPred = struct {
    // Integer comparison predicates
    pub const ICMP_EQ: u32 = 32;
    pub const ICMP_NE: u32 = 33;
    pub const ICMP_UGT: u32 = 34;
    pub const ICMP_UGE: u32 = 35;
    pub const ICMP_ULT: u32 = 36;
    pub const ICMP_ULE: u32 = 37;
    pub const ICMP_SGT: u32 = 38;
    pub const ICMP_SGE: u32 = 39;
    pub const ICMP_SLT: u32 = 40;
    pub const ICMP_SLE: u32 = 41;
    // Float comparison predicates
    pub const FCMP_OEQ: u32 = 1;
    pub const FCMP_OGT: u32 = 2;
    pub const FCMP_OGE: u32 = 3;
    pub const FCMP_OLT: u32 = 4;
    pub const FCMP_OLE: u32 = 5;
    pub const FCMP_ONE: u32 = 6;
    pub const FCMP_ORD: u32 = 7;
    pub const FCMP_UNO: u32 = 8;
};

// -- DXIL opcodes (dx.op intrinsic call arg0) --

pub const DxilOpcode = struct {
    pub const THREAD_ID: u32 = 93;
    pub const GROUP_ID: u32 = 94;
    pub const THREAD_ID_IN_GROUP: u32 = 95;
    pub const FLATTENED_THREAD_ID_IN_GROUP: u32 = 96;
    pub const CREATE_HANDLE: u32 = 57;
    pub const CBUFFER_LOAD_LEGACY: u32 = 59;
    pub const BUFFER_LOAD: u32 = 68;
    pub const BUFFER_STORE: u32 = 69;
    pub const BUFFER_UPDATE_COUNTER: u32 = 70;
    pub const ATOMIC_BINOP: u32 = 78;
    pub const ATOMIC_CMP_XCHG: u32 = 79;
    pub const BARRIER: u32 = 80;
    pub const TEXTURE_LOAD: u32 = 66;
    pub const TEXTURE_STORE: u32 = 67;
    pub const SAMPLE: u32 = 60;
    pub const SAMPLE_LEVEL: u32 = 62;
    pub const SAMPLE_CMP: u32 = 64;
    pub const GET_DIMENSIONS: u32 = 72;
    pub const TEXTURE_GATHER: u32 = 73;
    pub const BUFFER_STORE_RAW: u32 = 140;
    pub const BUFFER_LOAD_RAW: u32 = 139;
    pub const DOT2: u32 = 54;
    pub const DOT3: u32 = 55;
    pub const DOT4: u32 = 56;
    pub const WAVE_IS_FIRST_LANE: u32 = 110;
    pub const WAVE_GET_LANE_INDEX: u32 = 111;
    pub const WAVE_GET_LANE_COUNT: u32 = 112;
    pub const WAVE_ALL_TRUE: u32 = 114;
    pub const WAVE_ANY_TRUE: u32 = 113;
    pub const WAVE_ACTIVE_BALLOT: u32 = 116;
    pub const WAVE_READ_LANE_AT: u32 = 117;
    pub const WAVE_ACTIVE_OP: u32 = 119;
    pub const WAVE_ACTIVE_BIT: u32 = 120;
    pub const WAVE_PREFIX_OP: u32 = 121;
    pub const LOAD_INPUT: u32 = 4;
    pub const STORE_OUTPUT: u32 = 5;
    pub const EMIT_STREAM: u32 = 97;
    pub const CUT_STREAM: u32 = 98;
};

// Wave active op codes for WAVE_ACTIVE_OP
pub const WaveOp = struct {
    pub const SUM: u32 = 0;
    pub const PRODUCT: u32 = 1;
    pub const MIN: u32 = 2;
    pub const MAX: u32 = 3;
};

// Wave active bit op codes for WAVE_ACTIVE_BIT
pub const WaveBitOp = struct {
    pub const AND: u32 = 0;
    pub const OR: u32 = 1;
    pub const XOR: u32 = 2;
};

// Barrier modes for DXIL barrier intrinsic
pub const BarrierMode = struct {
    pub const SYNC_THREAD_GROUP: u32 = 1;
    pub const UAV_FENCE_GLOBAL: u32 = 2;
    pub const UAV_FENCE_THREAD_GROUP: u32 = 4;
    pub const TGSM_FENCE: u32 = 8;
};

// -- DXBC container format constants --

pub const DXBC_FOURCC: [4]u8 = .{ 'D', 'X', 'B', 'C' };
pub const DXBC_HEADER_SIZE: u32 = 32;
pub const DXBC_HASH_SIZE: u32 = 16;

pub const PartFourCC = struct {
    pub const DXIL: [4]u8 = .{ 'D', 'X', 'I', 'L' };
    pub const ISGN: [4]u8 = .{ 'I', 'S', 'G', 'N' };
    pub const OSGN: [4]u8 = .{ 'O', 'S', 'G', 'N' };
    pub const PSV0: [4]u8 = .{ 'P', 'S', 'V', '0' };
    pub const RDEF: [4]u8 = .{ 'R', 'D', 'E', 'F' };
    pub const SHDR: [4]u8 = .{ 'S', 'H', 'D', 'R' };
    pub const SFI0: [4]u8 = .{ 'S', 'F', 'I', '0' };
    pub const HASH: [4]u8 = .{ 'H', 'A', 'S', 'H' };
};

// DXIL program header values
pub const DXIL_PROGRAM_HEADER_SIZE: u32 = 24;
pub const DXIL_MINOR_VERSION: u32 = 0;
pub const DXIL_MAJOR_VERSION: u32 = 1;

// Shader type in the DXIL program header
pub const ShaderKind = struct {
    pub const PIXEL: u32 = 0;
    pub const VERTEX: u32 = 1;
    pub const GEOMETRY: u32 = 2;
    pub const HULL: u32 = 3;
    pub const DOMAIN: u32 = 4;
    pub const COMPUTE: u32 = 5;
};

// Shader model target triple components
pub const TARGET_DATALAYOUT: []const u8 = "e-m:e-p:32:32-i1:32-i8:8-i16:16-i32:32-i64:64-f16:16-f32:32-f64:64-n8:16:32:64";
pub const TARGET_TRIPLE_CS: []const u8 = "dxil-ms-dx";

// DXIL metadata tag IDs for shader properties
pub const DxilMdTag = struct {
    pub const SHADER_MODEL: u32 = 0;
    pub const RESOURCES: u32 = 1;
    pub const ENTRY_POINTS: u32 = 2;
    pub const SHADER_FLAGS: u32 = 3;
    pub const NUM_THREADS: u32 = 4;
    pub const SIGNATURE_ELEMENT: u32 = 5;
    pub const INPUT_SIG: u32 = 6;
    pub const OUTPUT_SIG: u32 = 7;
};

// DXIL resource class for resource metadata
pub const ResourceClass = struct {
    pub const SRV: u32 = 0;
    pub const UAV: u32 = 1;
    pub const CBV: u32 = 2;
    pub const SAMPLER: u32 = 3;
};

// DXIL resource kind for resource metadata
pub const ResourceKind = struct {
    pub const INVALID: u32 = 0;
    pub const TEXTURE_1D: u32 = 1;
    pub const TEXTURE_2D: u32 = 2;
    pub const TEXTURE_2D_MS: u32 = 3;
    pub const TEXTURE_3D: u32 = 4;
    pub const TEXTURE_CUBE: u32 = 5;
    pub const TYPED_BUFFER: u32 = 10;
    pub const RAW_BUFFER: u32 = 11;
    pub const STRUCTURED_BUFFER: u32 = 12;
    pub const CBUFFER: u32 = 13;
    pub const SAMPLER: u32 = 14;
    pub const TBUFFER: u32 = 15;
};

// DXIL component type for signature metadata
pub const ComponentType = struct {
    pub const INVALID: u32 = 0;
    pub const U32: u32 = 1;
    pub const I32: u32 = 2;
    pub const F32: u32 = 3;
    pub const U16: u32 = 4;
    pub const I16: u32 = 5;
    pub const F16: u32 = 6;
    pub const U64: u32 = 7;
    pub const I64: u32 = 8;
    pub const F64: u32 = 9;
};

// DXIL semantic kind for signature elements
pub const SemanticKind = struct {
    pub const ARBITRARY: u32 = 0;
    pub const VERTEX_ID: u32 = 1;
    pub const INSTANCE_ID: u32 = 2;
    pub const POSITION: u32 = 3;
    pub const RENDER_TARGET_ARRAY_INDEX: u32 = 4;
    pub const VIEWPORT_ARRAY_INDEX: u32 = 5;
    pub const CLIP_DISTANCE: u32 = 6;
    pub const CULL_DISTANCE: u32 = 7;
    pub const TARGET: u32 = 8;
    pub const DEPTH: u32 = 9;
    pub const COVERAGE: u32 = 10;
    pub const DISPATCH_THREAD_ID: u32 = 12;
    pub const GROUP_ID: u32 = 13;
    pub const GROUP_THREAD_ID: u32 = 14;
    pub const GROUP_INDEX: u32 = 15;
    pub const IS_FRONT_FACE: u32 = 16;
    pub const SAMPLE_INDEX: u32 = 17;
    pub const PRIMITIVE_ID: u32 = 18;
};

// Linkage types for LLVM module function records
pub const Linkage = struct {
    pub const EXTERNAL: u32 = 0;
    pub const INTERNAL: u32 = 8;
};
