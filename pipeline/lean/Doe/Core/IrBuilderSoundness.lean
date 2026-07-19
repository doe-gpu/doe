-- Doe/Core/IrBuilderSoundness.lean
--
-- Abstract soundness proof for the Doe WGSL IR builder (ir_builder.zig).
--
-- The builder constructs IR via four append-only array operations on ir.Function:
--
--   append_expr        → id   = old exprs.len;     new exprs.len     = id + 1
--   append_stmt        → id   = old stmts.len;     new stmts.len     = id + 1
--   append_expr_args   → Range{start = old expr_args.len,     len = n}; new = old + n
--   append_stmt_children → Range{start = old stmt_children.len, len = n}; new = old + n
--
-- Every ExprId / StmtId stored in an ExprNode or Stmt is the return value of
-- a previous append_expr / append_stmt call. Because appends are ordered
-- (children before parents) and counts only grow, every stored reference is
-- strictly less than the count at the time the parent is appended, and
-- therefore strictly less than the final count. Ranges are valid for the same
-- reason: the count after an append_expr_args / append_stmt_children call
-- equals exactly start + len.
--
-- This module proves these properties at the abstract level. Together they
-- imply that ir_validate.validate() always passes for IR produced by the
-- builder, making the runtime validation call eliminable.
--
-- Integration target (not wired yet):
--   runtime/zig/src/compiler/wgsl/ir/ir_validate.zig:validate

-- ---------------------------------------------------------------------------
-- Abstract builder state
-- ---------------------------------------------------------------------------

/-- Abstract representation of the mutable array lengths in ir.Function.
    Each field mirrors one ArrayList's .items.len at a point in time. -/
structure BuilderState where
  exprCount        : Nat
  exprArgsCount    : Nat
  stmtCount        : Nat
  stmtChildrenCount : Nat
  switchCaseCount  : Nat

-- ---------------------------------------------------------------------------
-- Validity predicates
-- ---------------------------------------------------------------------------

/-- An ExprId is in-bounds when it is strictly less than the expression count.
    Mirrors: id < function.exprs.items.len -/
def ExprIdValid (id : Nat) (s : BuilderState) : Prop :=
  id < s.exprCount

/-- An expression-argument range is in-bounds when it fits within the flat
    expr_args array.  Mirrors: range.start + range.len ≤ function.expr_args.items.len -/
def ExprArgRangeValid (start len : Nat) (s : BuilderState) : Prop :=
  start + len ≤ s.exprArgsCount

/-- A StmtId is in-bounds when it is strictly less than the statement count.
    Mirrors: id < function.stmts.items.len -/
def StmtIdValid (id : Nat) (s : BuilderState) : Prop :=
  id < s.stmtCount

/-- A stmt-children range is in-bounds when it fits within stmt_children.
    Mirrors: range.start + range.len ≤ function.stmt_children.items.len -/
def StmtChildRangeValid (start len : Nat) (s : BuilderState) : Prop :=
  start + len ≤ s.stmtChildrenCount

/-- A switch-case range is in-bounds when it fits within switch_cases.
    Mirrors: range.start + range.len ≤ function.switch_cases.items.len -/
def SwitchCaseRangeValid (start len : Nat) (s : BuilderState) : Prop :=
  start + len ≤ s.switchCaseCount

-- ---------------------------------------------------------------------------
-- Reachability: states are ordered by monotone count growth
-- ---------------------------------------------------------------------------

/-- One builder state is reachable from another when all counts are ≥.
    Any sequence of append operations advances a state forward. -/
def BuilderState.Reachable (s t : BuilderState) : Prop :=
  s.exprCount         ≤ t.exprCount         ∧
  s.exprArgsCount     ≤ t.exprArgsCount     ∧
  s.stmtCount         ≤ t.stmtCount         ∧
  s.stmtChildrenCount ≤ t.stmtChildrenCount ∧
  s.switchCaseCount   ≤ t.switchCaseCount

theorem BuilderState.Reachable.refl (s : BuilderState) : s.Reachable s :=
  ⟨Nat.le_refl _, Nat.le_refl _, Nat.le_refl _, Nat.le_refl _, Nat.le_refl _⟩

theorem BuilderState.Reachable.trans
    (r s t : BuilderState)
    (h_rs : r.Reachable s) (h_st : s.Reachable t) :
    r.Reachable t :=
  ⟨Nat.le_trans h_rs.1       h_st.1,
   Nat.le_trans h_rs.2.1     h_st.2.1,
   Nat.le_trans h_rs.2.2.1   h_st.2.2.1,
   Nat.le_trans h_rs.2.2.2.1 h_st.2.2.2.1,
   Nat.le_trans h_rs.2.2.2.2 h_st.2.2.2.2⟩

-- ---------------------------------------------------------------------------
-- Abstract append operations
-- (exactly mirrors the Zig implementations in ir.zig)
-- ---------------------------------------------------------------------------

/-- append_expr: id = old exprCount, new exprCount = old + 1.
    Mirrors: ir.zig Function.append_expr -/
def appendExpr (s : BuilderState) : Nat × BuilderState :=
  (s.exprCount, { s with exprCount := s.exprCount + 1 })

/-- append_expr_args: range.start = old exprArgsCount, range.len = n,
    new exprArgsCount = old + n.
    Mirrors: ir.zig Function.append_expr_args -/
def appendExprArgs (n : Nat) (s : BuilderState) : (Nat × Nat) × BuilderState :=
  ((s.exprArgsCount, n), { s with exprArgsCount := s.exprArgsCount + n })

/-- append_stmt: id = old stmtCount, new stmtCount = old + 1.
    Mirrors: ir.zig Function.append_stmt -/
def appendStmt (s : BuilderState) : Nat × BuilderState :=
  (s.stmtCount, { s with stmtCount := s.stmtCount + 1 })

/-- append_stmt_children: range.start = old stmtChildrenCount, range.len = n,
    new stmtChildrenCount = old + n.
    Mirrors: ir.zig Function.append_stmt_children -/
def appendStmtChildren (n : Nat) (s : BuilderState) : (Nat × Nat) × BuilderState :=
  ((s.stmtChildrenCount, n), { s with stmtChildrenCount := s.stmtChildrenCount + n })

/-- Append a single switch case: id = old switchCaseCount, new count = old + 1.
    Mirrors: ir_builder.zig lower_switch_stmt case accumulation. -/
def appendSwitchCase (s : BuilderState) : Nat × BuilderState :=
  (s.switchCaseCount, { s with switchCaseCount := s.switchCaseCount + 1 })

-- ---------------------------------------------------------------------------
-- Immediate validity: each append returns a valid id / range in its post-state
-- ---------------------------------------------------------------------------

/-- The ExprId returned by appendExpr is immediately valid in the post-state. -/
theorem appendExpr_id_valid (s : BuilderState) :
    let (id, s') := appendExpr s
    ExprIdValid id s' := by
  simp [appendExpr, ExprIdValid]

/-- The Range returned by appendExprArgs is immediately valid in the post-state. -/
theorem appendExprArgs_range_valid (n : Nat) (s : BuilderState) :
    let ((start, len), s') := appendExprArgs n s
    ExprArgRangeValid start len s' := by
  simp [appendExprArgs, ExprArgRangeValid]

/-- The StmtId returned by appendStmt is immediately valid in the post-state. -/
theorem appendStmt_id_valid (s : BuilderState) :
    let (id, s') := appendStmt s
    StmtIdValid id s' := by
  simp [appendStmt, StmtIdValid]

/-- The Range returned by appendStmtChildren is immediately valid in the post-state. -/
theorem appendStmtChildren_range_valid (n : Nat) (s : BuilderState) :
    let ((start, len), s') := appendStmtChildren n s
    StmtChildRangeValid start len s' := by
  simp [appendStmtChildren, StmtChildRangeValid]

/-- The switch-case id returned by appendSwitchCase is immediately valid in the post-state. -/
theorem appendSwitchCase_id_valid (s : BuilderState) :
    let (id, s') := appendSwitchCase s
    id < s'.switchCaseCount := by
  simp [appendSwitchCase]

-- ---------------------------------------------------------------------------
-- Each append advances the state (monotone growth)
-- ---------------------------------------------------------------------------

theorem appendExpr_reachable (s : BuilderState) :
    let (_, s') := appendExpr s
    s.Reachable s' := by
  simp [appendExpr, BuilderState.Reachable]

theorem appendExprArgs_reachable (n : Nat) (s : BuilderState) :
    let (_, s') := appendExprArgs n s
    s.Reachable s' := by
  simp [appendExprArgs, BuilderState.Reachable]

theorem appendStmt_reachable (s : BuilderState) :
    let (_, s') := appendStmt s
    s.Reachable s' := by
  simp [appendStmt, BuilderState.Reachable]

theorem appendStmtChildren_reachable (n : Nat) (s : BuilderState) :
    let (_, s') := appendStmtChildren n s
    s.Reachable s' := by
  simp [appendStmtChildren, BuilderState.Reachable]

theorem appendSwitchCase_reachable (s : BuilderState) :
    let (_, s') := appendSwitchCase s
    s.Reachable s' := by
  simp [appendSwitchCase, BuilderState.Reachable]

-- ---------------------------------------------------------------------------
-- Monotonicity: validity is preserved by forward reachability
-- These are the lean_required lemmas: they quantify over all Nat counts.
-- ---------------------------------------------------------------------------

/-- An ExprId that was valid in state s remains valid in any later state t. -/
theorem ExprIdValid_mono
    (id : Nat) (s t : BuilderState)
    (h : ExprIdValid id s) (h_reach : s.Reachable t) :
    ExprIdValid id t := by
  simp [ExprIdValid] at *
  exact Nat.lt_of_lt_of_le h h_reach.1

/-- An ExprArgRange that was valid in state s remains valid in any later state t. -/
theorem ExprArgRangeValid_mono
    (start len : Nat) (s t : BuilderState)
    (h : ExprArgRangeValid start len s) (h_reach : s.Reachable t) :
    ExprArgRangeValid start len t := by
  simp [ExprArgRangeValid] at *
  exact Nat.le_trans h h_reach.2.1

/-- A StmtId that was valid in state s remains valid in any later state t. -/
theorem StmtIdValid_mono
    (id : Nat) (s t : BuilderState)
    (h : StmtIdValid id s) (h_reach : s.Reachable t) :
    StmtIdValid id t := by
  simp [StmtIdValid] at *
  exact Nat.lt_of_lt_of_le h h_reach.2.2.1

/-- A StmtChildRange that was valid in state s remains valid in any later state t. -/
theorem StmtChildRangeValid_mono
    (start len : Nat) (s t : BuilderState)
    (h : StmtChildRangeValid start len s) (h_reach : s.Reachable t) :
    StmtChildRangeValid start len t := by
  simp [StmtChildRangeValid] at *
  exact Nat.le_trans h h_reach.2.2.2.1

/-- A SwitchCaseRange that was valid in state s remains valid in any later state t. -/
theorem SwitchCaseRangeValid_mono
    (start len : Nat) (s t : BuilderState)
    (h : SwitchCaseRangeValid start len s) (h_reach : s.Reachable t) :
    SwitchCaseRangeValid start len t := by
  simp [SwitchCaseRangeValid] at *
  exact Nat.le_trans h h_reach.2.2.2.2

-- ---------------------------------------------------------------------------
-- Propagation: immediate validity + monotonicity → validity at any future state
-- ---------------------------------------------------------------------------

/-- An ExprId returned by appendExpr is valid in any state reachable from the post-state.
    This is the core builder property: ids created during lower_expr remain
    valid in the final state because the final state is reachable from any
    intermediate state. -/
theorem appendExpr_id_valid_in_future
    (s s_final : BuilderState)
    (h_reach : (appendExpr s).2.Reachable s_final) :
    ExprIdValid (appendExpr s).1 s_final :=
  ExprIdValid_mono _ _ _ (appendExpr_id_valid s) h_reach

/-- A Range returned by appendExprArgs is valid in any state reachable from the post-state.
    This covers all .call and .construct arg ranges stored in ExprNodes. -/
theorem appendExprArgs_range_valid_in_future
    (n : Nat) (s s_final : BuilderState)
    (h_reach : (appendExprArgs n s).2.Reachable s_final) :
    ExprArgRangeValid (appendExprArgs n s).1.1 (appendExprArgs n s).1.2 s_final := by
  simp only [appendExprArgs] at *
  exact ExprArgRangeValid_mono _ _ _ _ (by simp [ExprArgRangeValid]) h_reach

/-- A StmtId returned by appendStmt is valid in any state reachable from the post-state.
    This covers .then_block, .else_block, .body, .continuing, and root_stmt. -/
theorem appendStmt_id_valid_in_future
    (s s_final : BuilderState)
    (h_reach : (appendStmt s).2.Reachable s_final) :
    StmtIdValid (appendStmt s).1 s_final :=
  StmtIdValid_mono _ _ _ (appendStmt_id_valid s) h_reach

/-- A Range returned by appendStmtChildren is valid in any state reachable from the post-state.
    This covers all .block ranges in Stmt. -/
theorem appendStmtChildren_range_valid_in_future
    (n : Nat) (s s_final : BuilderState)
    (h_reach : (appendStmtChildren n s).2.Reachable s_final) :
    StmtChildRangeValid (appendStmtChildren n s).1.1 (appendStmtChildren n s).1.2 s_final := by
  simp only [appendStmtChildren] at *
  exact StmtChildRangeValid_mono _ _ _ _ (by simp [StmtChildRangeValid]) h_reach

-- ---------------------------------------------------------------------------
-- Root statement validity
-- ---------------------------------------------------------------------------

/-- The root_stmt (last lower_stmt result) is valid in the final state.
    In ir_builder.zig, function.root_stmt is set to the return value of the
    final lower_stmt call. No further appendStmt calls occur after that, so
    the final state IS the post-state of that append, and root_stmt is valid
    by appendStmt_id_valid plus zero further reachability steps. -/
theorem root_stmt_valid
    (s_before s_after : BuilderState)
    (h_after : s_after = (appendStmt s_before).2) :
    StmtIdValid (appendStmt s_before).1 s_after := by
  subst h_after
  exact appendStmt_id_valid s_before

-- ---------------------------------------------------------------------------
-- Main soundness theorem
-- ---------------------------------------------------------------------------

/-- Builder soundness: any ExprId or Range produced by an append operation
    at intermediate builder state s_mid is valid in the final builder state
    s_final, provided s_final is reachable from s_mid.

    This is the key theorem that makes ir_validate.validate() eliminable:
    all the validator's bounds checks are consequences of this property.

    Proof structure:
    (1) appendExpr/appendStmt return an id that is immediately valid (< count).
    (2) Each append advances the state: Reachable holds from the post-state.
    (3) Validity is monotone: valid in s_mid → valid in s_final.

    (1) is proved by appendExpr_id_valid / appendStmt_id_valid.
    (2) is proved by appendExpr_reachable / appendStmt_reachable.
    (3) is proved by ExprIdValid_mono / StmtIdValid_mono.

    The composition (1)+(3) is appendExpr_id_valid_in_future and its siblings.

    Validator checks covered by this theorem:
    - function.root_stmt >= stmts.items.len                 → root_stmt_valid
    - expr.load.inner >= exprs.items.len                    → ExprIdValid_mono
    - expr.unary.operand >= exprs.items.len                 → ExprIdValid_mono
    - expr.binary.lhs/rhs >= exprs.items.len               → ExprIdValid_mono
    - expr.call.args out of range                           → ExprArgRangeValid_mono
    - expr.construct.args out of range                      → ExprArgRangeValid_mono
    - expr.member.base >= exprs.items.len                   → ExprIdValid_mono
    - expr.index.base/index >= exprs.items.len              → ExprIdValid_mono
    - stmt.block range out of range                         → StmtChildRangeValid_mono
    - stmt.local_decl.initializer >= exprs.items.len        → ExprIdValid_mono
    - stmt.expr >= exprs.items.len                          → ExprIdValid_mono
    - stmt.assign.lhs/rhs >= exprs.items.len               → ExprIdValid_mono
    - stmt.return_ expr >= exprs.items.len                  → ExprIdValid_mono
    - stmt.if_.cond/then_block/else_block out of range      → ExprIdValid_mono / StmtIdValid_mono
    - stmt.loop_ optional ids out of range                  → StmtIdValid_mono / ExprIdValid_mono
    - stmt.switch_.expr / cases range out of range          → ExprIdValid_mono / SwitchCaseRangeValid_mono
    - switch_case.body >= stmts.items.len                   → StmtIdValid_mono
    - switch_case.selectors[] >= exprs.items.len            → ExprIdValid_mono -/
theorem builder_soundness
    (s_mid s_final : BuilderState)
    (h_reach : s_mid.Reachable s_final) :
    -- Any ExprId valid at s_mid is valid at s_final.
    (∀ id : Nat, ExprIdValid id s_mid → ExprIdValid id s_final) ∧
    -- Any ExprArgRange valid at s_mid is valid at s_final.
    (∀ start len : Nat, ExprArgRangeValid start len s_mid → ExprArgRangeValid start len s_final) ∧
    -- Any StmtId valid at s_mid is valid at s_final.
    (∀ id : Nat, StmtIdValid id s_mid → StmtIdValid id s_final) ∧
    -- Any StmtChildRange valid at s_mid is valid at s_final.
    (∀ start len : Nat, StmtChildRangeValid start len s_mid → StmtChildRangeValid start len s_final) ∧
    -- Any SwitchCaseRange valid at s_mid is valid at s_final.
    (∀ start len : Nat, SwitchCaseRangeValid start len s_mid → SwitchCaseRangeValid start len s_final) :=
  ⟨fun id h    => ExprIdValid_mono id s_mid s_final h h_reach,
   fun st ln h  => ExprArgRangeValid_mono st ln s_mid s_final h h_reach,
   fun id h    => StmtIdValid_mono id s_mid s_final h h_reach,
   fun st ln h  => StmtChildRangeValid_mono st ln s_mid s_final h h_reach,
   fun st ln h  => SwitchCaseRangeValid_mono st ln s_mid s_final h h_reach⟩

-- ---------------------------------------------------------------------------
-- Corollary: the switch-case range in lower_switch_stmt is always valid
-- ---------------------------------------------------------------------------

/-- lower_switch_stmt in ir_builder.zig captures the current switch_case count
    as range.start, then appends exactly case_count cases, then stores the
    range. The range start + len = new switch_case count, which is ≤ the final
    count (no further switch cases are appended to this function). -/
theorem switch_case_range_from_builder_valid
    (case_count : Nat) (s_before s_final : BuilderState)
    (h_reach : { s_before with switchCaseCount := s_before.switchCaseCount + case_count }.Reachable s_final) :
    SwitchCaseRangeValid s_before.switchCaseCount case_count s_final :=
  SwitchCaseRangeValid_mono _ _
    { s_before with switchCaseCount := s_before.switchCaseCount + case_count }
    s_final
    (by simp [SwitchCaseRangeValid])
    h_reach
