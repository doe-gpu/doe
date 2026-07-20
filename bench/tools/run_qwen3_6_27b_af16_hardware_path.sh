#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly RDRR_REPO="clocksmith/rdrr"
readonly RDRR_REVISION="3dee21b3b12d65ac7fef9b24cbf759cacc953a67"
readonly AF16_MODEL_PATH="models/qwen-3-6-27b-q4k-eaf16"
readonly SHARED_WEIGHT_PATH="models/qwen-3-6-27b-q4k-ehaf16"
readonly SMOKE_CONFIG="runtime/zig/examples/execution-v1/qwen-3-6-27b-smoke.json"
readonly RUNNER="bench/runners/csl-runners/qwen3_6_27b_af16_hostplan_streaming_runner.py"
readonly DEFAULT_OUT_ROOT="bench/out/hardware-run"
readonly DEFAULT_HOSTPLAN_DIR="bench/fixtures/cerebras-hostplans/qwen3-6-27b-af16"

archive=""
cmaddr="${CMADDR:-}"
hf_token="${HF_TOKEN:-}"
python_bin="${PYTHON:-python3}"
cslc_executable="${DOE_CSLC_EXECUTABLE:-cslc}"
rdrr_root="${DOE_RDRR_ROOT:-}"
out_root="$DEFAULT_OUT_ROOT"
hostplan_dir="$DEFAULT_HOSTPLAN_DIR"
rebuild_hostplan=0
skip_sdk_compile=0
skip_archive_verify=0
skip_fetch=0
skip_hf_login=0
dry_run=0
session_embed_roi_hidden_per_pe="${DOE_SESSION_EMBED_ROI_HIDDEN_PER_PE:-512}"
session_embed_roi_jobs="${DOE_SESSION_EMBED_ROI_JOBS:-1}"

usage() {
  cat <<'EOF'
Usage:
  bench/tools/run_qwen3_6_27b_af16_hardware_path.sh \
    --cmaddr <endpoint>

Required for hardware execution:
  --cmaddr <endpoint>        Cerebras endpoint passed to the runner.

Common options:
  --archive <path>           Verify this archive before running.
                             Default: archive named by the bundle pointer.
  --hf-token <token>         Optional token for fetching clocksmith/rdrr.
  --rdrr-root <path>         Local root for the clocksmith/rdrr checkout.
                             Default: ../rdrr-cache/Clocksmith-rdrr.
  --out-root <path>          Output root. Default: bench/out/hardware-run.
  --cslc-executable <path>   cslc executable. Default: cslc.
  --python <path>            Python executable. Default: python3.
  --skip-archive-verify      Do not verify --archive.
  --skip-fetch               Do not fetch clocksmith/rdrr; validate local files.
  --skip-hf-login            Do not call hf auth login.
  --dry-run                  Print the runner command without launching it.
  --session-embed-roi-hidden-per-pe <n>
                             Forwarded to the HostPlan runner. Default: 512.
                             Use 0 to keep the HostPlan compile parameter.
  --session-embed-roi-jobs <n>
                             Forwarded to the HostPlan runner. Default: 1.

HostPlan options:
  --hostplan-root <path>     Directory containing host-plan.json,
                             simulator-plan.json, runtime-config.json,
                             and compile/.
                             Default: bundled Qwen af16 HostPlan source.
  --rebuild-hostplan         Regenerate HostPlan/CSL from execution-v1 input.
                             Requires zig.
  --skip-sdk-compile         Do not run csl_sdk_driver.py. Use only when
                             --hostplan-root already contains SDK compile
                             outputs under compile/.

This script does not clone Doe or create a virtualenv. Run it from a checkout
at the evidence-bundle commit after installing numpy, jsonschema, and
huggingface_hub.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command on PATH: $1"
}

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
  esac
}

rel_path() {
  local path="$1"
  case "$path" in
    "$REPO_ROOT"/*) printf '%s\n' "${path#"$REPO_ROOT/"}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      archive="${2:-}"
      shift 2
      ;;
    --cmaddr)
      cmaddr="${2:-}"
      shift 2
      ;;
    --hf-token)
      hf_token="${2:-}"
      shift 2
      ;;
    --rdrr-root)
      rdrr_root="${2:-}"
      shift 2
      ;;
    --out-root)
      out_root="${2:-}"
      shift 2
      ;;
    --hostplan-root)
      hostplan_dir="${2:-}"
      shift 2
      ;;
    --cslc-executable)
      cslc_executable="${2:-}"
      shift 2
      ;;
    --python)
      python_bin="${2:-}"
      shift 2
      ;;
    --use-existing-hostplan)
      rebuild_hostplan=0
      shift
      ;;
    --rebuild-hostplan)
      rebuild_hostplan=1
      shift
      ;;
    --skip-sdk-compile)
      skip_sdk_compile=1
      shift
      ;;
    --skip-archive-verify)
      skip_archive_verify=1
      shift
      ;;
    --skip-fetch)
      skip_fetch=1
      shift
      ;;
    --skip-hf-login)
      skip_hf_login=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --session-embed-roi-hidden-per-pe)
      session_embed_roi_hidden_per_pe="${2:-}"
      shift 2
      ;;
    --session-embed-roi-jobs)
      session_embed_roi_jobs="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ "$dry_run" -eq 0 ]]; then
  [[ -n "$cmaddr" ]] || die "--cmaddr is required for hardware execution"
fi

cd "$REPO_ROOT"

need_cmd "$python_bin"

"$python_bin" - <<'PY'
import importlib.util
import sys

missing = [
    name
    for name in ("numpy", "jsonschema", "huggingface_hub")
    if importlib.util.find_spec(name) is None
]
if missing:
    print(
        "missing Python packages: "
        + ", ".join(missing)
        + "\ninstall with: python3 -m pip install numpy jsonschema huggingface_hub",
        file=sys.stderr,
    )
    raise SystemExit(2)
PY

if [[ -z "$archive" && "$skip_archive_verify" -eq 0 ]]; then
  archive="$(
    sed -n 's/^| archive | `\(bench\/out\/doe-cerebras-evidence-[^`]*\.tar\.gz\)` |$/\1/p' \
      docs/cerebras-evidence-bundle-pointer.md 2>/dev/null | head -1
  )"
fi

if [[ -n "$archive" && "$skip_archive_verify" -eq 0 ]]; then
  "$python_bin" bench/tools/verify_cerebras_validation_archive.py \
    --archive "$archive"
elif [[ "$skip_archive_verify" -eq 0 ]]; then
  die "no bundled archive found under bench/out/; pass --archive <path> or --skip-archive-verify"
fi

rdrr_root="${rdrr_root:-$REPO_ROOT/../rdrr-cache/Clocksmith-rdrr}"
rdrr_root="$(abs_path "$rdrr_root")"
out_root="$(abs_path "$out_root")"
hostplan_dir="$(abs_path "$hostplan_dir")"
mkdir -p "$out_root"

if [[ "$skip_fetch" -eq 0 && "$dry_run" -eq 0 ]]; then
  need_cmd hf

  if [[ "$skip_hf_login" -eq 0 && -n "$hf_token" ]]; then
    hf auth login --token "$hf_token" --add-to-git-credential false
  fi

  hf download "$RDRR_REPO" \
    --repo-type model \
    --revision "$RDRR_REVISION" \
    --include "$AF16_MODEL_PATH/*" \
    --include "$SHARED_WEIGHT_PATH/*" \
    --local-dir "$rdrr_root"
fi

readonly AF16_MANIFEST="$rdrr_root/$AF16_MODEL_PATH/manifest.json"
export DOE_QWEN3_6_27B_AF16_MANIFEST="$AF16_MANIFEST"

if [[ "$dry_run" -eq 0 ]]; then
  "$python_bin" - <<'PY'
import hashlib
import json
import os
from pathlib import Path

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()

manifest_path = Path(os.environ["DOE_QWEN3_6_27B_AF16_MANIFEST"]).resolve()
if not manifest_path.is_file():
    raise SystemExit(f"missing Doppler manifest: {manifest_path}")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if manifest.get("modelId") != "qwen-3-6-27b-q4k-eaf16":
    raise SystemExit(f"unexpected modelId in {manifest_path}")
weights_ref = manifest.get("weightsRef") or {}
weights_root = (manifest_path.parent / weights_ref.get("artifactRoot", "")).resolve()
weights_manifest_path = weights_root / "manifest.json"
if not weights_manifest_path.is_file():
    raise SystemExit(f"missing weights manifest: {weights_manifest_path}")
weights_manifest = json.loads(weights_manifest_path.read_text(encoding="utf-8"))
if sha256_file(weights_manifest_path) != weights_ref.get("manifestDigest"):
    raise SystemExit(f"weights manifest digest mismatch: {weights_manifest_path}")
if (
    weights_manifest.get("artifactIdentity", {}).get("shardSetHash")
    != weights_ref.get("shardSetHash")
):
    raise SystemExit(f"weights shardSetHash mismatch: {weights_manifest_path}")
missing = [
    shard.get("filename")
    for shard in weights_manifest.get("shards", [])
    if not (weights_root / str(shard.get("filename"))).is_file()
]
if missing:
    raise SystemExit(f"missing Doppler weight shards: {missing[:5]}")
print(f"validated {manifest_path}")
PY
fi

validate_hostplan_dir() {
  local dir="$1"
  [[ -f "$dir/host-plan.json" ]] || die "missing $dir/host-plan.json"
  [[ -f "$dir/simulator-plan.json" ]] || die "missing $dir/simulator-plan.json"
  [[ -f "$dir/runtime-config.json" ]] || die "missing $dir/runtime-config.json"
  [[ -d "$dir/compile" ]] || die "missing $dir/compile"
}

if [[ "$rebuild_hostplan" -eq 1 ]]; then
  if ! command -v zig >/dev/null 2>&1; then
    die "zig is required with --rebuild-hostplan; omit --rebuild-hostplan to use the bundled HostPlan source"
  fi

  zig build csl-host-plan-tool

  runtime/zig/zig-out/bin/doe-csl-host-plan-tool \
    --input "$SMOKE_CONFIG" \
    --bundle-root "$(rel_path "$hostplan_dir")" \
    --mode steps \
    --cslc-executable "$cslc_executable"
fi

validate_hostplan_dir "$hostplan_dir"

if [[ "$skip_sdk_compile" -eq 0 && "$dry_run" -eq 0 ]]; then
  need_cmd "$cslc_executable"
  "$python_bin" runtime/zig/tools/csl_sdk_driver.py \
    "$(rel_path "$hostplan_dir")/simulator-plan.json" \
    --cslc-executable "$cslc_executable"
fi

readonly session_out_dir="$out_root/qwen3-6-27b-af16-session"
readonly trace_out="$out_root/qwen3-6-27b-af16-trace.json"

runner_cmd=(
  "$python_bin" "$RUNNER"
  --source-doppler-manifest "$AF16_MANIFEST"
  --smoke-config "$SMOKE_CONFIG"
  --host-plan "$hostplan_dir/host-plan.json"
  --simulator-plan "$hostplan_dir/simulator-plan.json"
  --runtime-config "$hostplan_dir/runtime-config.json"
  --compile-root "$hostplan_dir/compile"
  --prefill-token-count 18
  --decode-token-count 8
  --prompt-token-id 248045
  --prompt-token-id 846
  --prompt-token-id 198
  --prompt-token-id 760
  --prompt-token-id 1829
  --prompt-token-id 314
  --prompt-token-id 279
  --prompt-token-id 12515
  --prompt-token-id 369
  --prompt-token-id 248046
  --prompt-token-id 198
  --prompt-token-id 248045
  --prompt-token-id 74455
  --prompt-token-id 198
  --prompt-token-id 248068
  --prompt-token-id 271
  --prompt-token-id 248069
  --prompt-token-id 271
  --execute
  --cmaddr "$cmaddr"
  --session-lm-head-dispatch-mode dense_gemv_width_tiled_session
  --session-lm-head-tile-width 32
  --session-lm-head-tile-dispatch-budget 0
  --session-embed-roi-hidden-per-pe "$session_embed_roi_hidden_per_pe"
  --session-embed-roi-jobs "$session_embed_roi_jobs"
  --session-prefill-q4k-gemv-output-pe-rows 4
  --session-out-dir "$session_out_dir"
  --out "$trace_out"
)

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Would run:\n'
  printf '  %q' "${runner_cmd[@]}"
  printf '\n'
  exit 0
fi

set +e
"${runner_cmd[@]}"
runner_rc=$?
set -e

cat <<EOF

Return these artifacts when present:
  $trace_out
  $session_out_dir/trace.json
  $session_out_dir/progress.jsonl
  any *.driver-result.json under $out_root
EOF

exit "$runner_rc"
