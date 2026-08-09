pub const DEFAULT_POLICY_PATH = "config/numeric-stability-policy.json";
pub const DEFAULT_OPERATOR_FAMILY = "lm-head-slice";
pub const DEFAULT_TRIGGER_POLICY_ID = "numeric-instability/selected-token-disagreement-with-reference-improvement-v1";
pub const DEFAULT_ROUTING_POLICY_ID = "numeric-stability/prefer-stable-on-selected-token-disagreement-v1";
pub const DEFAULT_FAST_POLICY_ID = "lm-head-slice/forward-f16accum-v1";
pub const DEFAULT_STABLE_POLICY_ID = "lm-head-slice/forward-serial-v1";
pub const DEFAULT_FAST_KERNEL_BASENAME = "matmul_logits_forward_f16accum.wgsl";

pub const VectorCapture = struct {
    buffer_handle: u64,
    offset: u64 = 0,
    element_count: u32,
};

pub const WeightsCapture = struct {
    buffer_handle: u64,
    offset: u64 = 0,
    row_stride_elements: u32,
};

pub const Candidate = struct {
    token_id: u32,
    label: ?[]const u8 = null,
    row_index: u32,
    bias: ?f64 = null,
};

pub const Annotation = struct {
    operator_family: []const u8 = DEFAULT_OPERATOR_FAMILY,
    trigger_policy_id: []const u8 = DEFAULT_TRIGGER_POLICY_ID,
    routing_policy_id: []const u8 = DEFAULT_ROUTING_POLICY_ID,
    fast_policy_id: []const u8 = DEFAULT_FAST_POLICY_ID,
    stable_policy_id: []const u8 = DEFAULT_STABLE_POLICY_ID,
    hidden_state: VectorCapture,
    logits: VectorCapture,
    weights: WeightsCapture,
    candidates: []const Candidate,
};
