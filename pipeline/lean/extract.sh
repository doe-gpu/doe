#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="$(mktemp -d /tmp/doe-lean-extract.XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
mkdir -p "${BUILD_DIR}/Doe/Core"
mkdir -p "${BUILD_DIR}/Doe/Full"
mkdir -p "${BUILD_DIR}/Doe/Generated"
mkdir -p "${BUILD_DIR}/Doe/Shader"

# shellcheck source=lean_build_common.sh
python3 "$(dirname "${BASH_SOURCE[0]}")/generate_comparability_contract.py"
. "$(dirname "${BASH_SOURCE[0]}")/lean_build_common.sh"

ARTIFACT_DIR="${ROOT_DIR}/pipeline/lean/artifacts"
ARTIFACT_PATH="${ARTIFACT_DIR}/proven-conditions.json"
mkdir -p "${ARTIFACT_DIR}"

while IFS='=' read -r key value; do
  export "${key}=${value}"
done < <(python3 - "${ROOT_DIR}" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
lean_root = root / "pipeline" / "lean" / "Doe"

def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

tree_hash = hashlib.sha256()
for path in sorted(lean_root.rglob("*.lean")):
    relative = path.relative_to(root).as_posix()
    tree_hash.update(relative.encode("utf-8"))
    tree_hash.update(b"\n")
    tree_hash.update(path.read_bytes())
    tree_hash.update(b"\n")

print(f"DOE_LEAN_EXTRACT_PROGRAM_SHA256={sha256_file(root / 'pipeline/lean/Doe/Extract.lean')}")
print(f"DOE_LEAN_SOURCE_TREE_SHA256={tree_hash.hexdigest()}")
print(
    "DOE_LEAN_GENERATED_COMPARABILITY_CONTRACT_SHA256="
    f"{sha256_file(root / 'pipeline/lean/Doe/Generated/ComparabilityContract.lean')}"
)
print(f"DOE_LEAN_PROOF_PATTERN_SPEC_SHA256={sha256_file(root / 'config/lean-proof-patterns.json')}")
PY
)

# Run extraction: compile Extract.lean and execute its main to produce the artifact.
LEAN_PATH="${BUILD_DIR}:${ROOT_DIR}/pipeline/lean" \
  DOE_LEAN_TOOLCHAIN_REF="${TOOLCHAIN_REF}" \
  DOE_LEAN_EXTRACT_PROGRAM_SHA256="${DOE_LEAN_EXTRACT_PROGRAM_SHA256}" \
  DOE_LEAN_SOURCE_TREE_SHA256="${DOE_LEAN_SOURCE_TREE_SHA256}" \
  DOE_LEAN_GENERATED_COMPARABILITY_CONTRACT_SHA256="${DOE_LEAN_GENERATED_COMPARABILITY_CONTRACT_SHA256}" \
  DOE_LEAN_PROOF_PATTERN_SPEC_SHA256="${DOE_LEAN_PROOF_PATTERN_SPEC_SHA256}" \
  "${LEAN_BIN}" "+${TOOLCHAIN_REF}" --run "${ROOT_DIR}/pipeline/lean/Doe/Extract.lean" > "${ARTIFACT_PATH}"

python3 "${ROOT_DIR}/pipeline/lean/finalize_proof_artifact.py" \
  --root "${ROOT_DIR}" \
  --artifact "${ARTIFACT_PATH}"

echo "lean-extract: artifact written to ${ARTIFACT_PATH} (${TOOLCHAIN_REF})"
