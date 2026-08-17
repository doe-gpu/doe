#!/usr/bin/env bash
# Shared toolchain resolution and Lean compilation block.
# Source this file after BUILD_DIR is set by the caller.
# Sets: ROOT_DIR, TOOLCHAIN_VERSION, TOOLCHAIN_REF, LEAN_BIN

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLCHAIN_VERSION="$(jq -r '.toolchains.lean.version // empty' "$ROOT_DIR/config/toolchains.json" 2>/dev/null || true)"

if [[ -z "${TOOLCHAIN_VERSION}" ]]; then
  TOOLCHAIN_VERSION="4.16.0"
fi

if [[ "${TOOLCHAIN_VERSION}" == v* ]]; then
  TOOLCHAIN_REF="leanprover/lean4:${TOOLCHAIN_VERSION}"
else
  TOOLCHAIN_REF="leanprover/lean4:v${TOOLCHAIN_VERSION}"
fi

if [[ -x "${HOME}/.elan/bin/lean" ]]; then
  LEAN_BIN="${HOME}/.elan/bin/lean"
elif command -v lean >/dev/null 2>&1; then
  LEAN_BIN="$(command -v lean)"
else
  echo "lean binary not found. Install Lean with elan first." >&2
  exit 1
fi

# Core layer (canonical sources).
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/Model.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/Model.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/Runtime.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/Runtime.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/Dispatch.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/Dispatch.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/DeterminismPolicy.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/DeterminismPolicy.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/NumericStabilityPolicy.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/NumericStabilityPolicy.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/Bridge.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/Bridge.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/BindGroupSlot.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/BindGroupSlot.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/BufferLifecycle.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/BufferLifecycle.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/IrBuilderSoundness.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/IrBuilderSoundness.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/IrSemanticContract.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/IrSemanticContract.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/IrValidatorRedundancy.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/IrValidatorRedundancy.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/RenderPassStateMachine.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/RenderPassStateMachine.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/MslAddressSpace.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/MslAddressSpace.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/BufferDispatchPrecondition.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/BufferDispatchPrecondition.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/IrTypePreserved.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/IrTypePreserved.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Core/IrOptRewrite.olean" "${ROOT_DIR}/pipeline/lean/Doe/Core/IrOptRewrite.lean"

# Full layer (canonical sources).
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Generated/ComparabilityContract.olean" "${ROOT_DIR}/pipeline/lean/Doe/Generated/ComparabilityContract.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Full/Comparability.olean" "${ROOT_DIR}/pipeline/lean/Doe/Full/Comparability.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Full/ComparabilityFixtures.olean" "${ROOT_DIR}/pipeline/lean/Doe/Full/ComparabilityFixtures.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Full/WorkloadGeometry.olean" "${ROOT_DIR}/pipeline/lean/Doe/Full/WorkloadGeometry.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Shader/Tactics.olean" "${ROOT_DIR}/pipeline/lean/Doe/Shader/Tactics.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Shader/ComputeBounds.olean" "${ROOT_DIR}/pipeline/lean/Doe/Shader/ComputeBounds.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Shader/TextureSampleBounds.olean" "${ROOT_DIR}/pipeline/lean/Doe/Shader/TextureSampleBounds.lean"
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Shader/BoundsElisionMatcher.olean" "${ROOT_DIR}/pipeline/lean/Doe/Shader/BoundsElisionMatcher.lean"

# Legacy compat shell (Doe/Model.lean re-exports Doe.Core.Model plus enum constructors).
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" -o "${BUILD_DIR}/Doe/Model.olean" "${ROOT_DIR}/pipeline/lean/Doe/Model.lean"
