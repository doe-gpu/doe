#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lane-paths.sh"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
artifact_dir="${FAWN_RUNTIME_BENCH_OUT_DIR:-${FAWN_REPO_ROOT}/browser/chromium/artifacts/${timestamp}}"
report_path="${artifact_dir}/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json"
summary_path="${artifact_dir}/fawn-dawn-vs-fawn-doe.browser-layered.superset.summary.json"
check_path="${artifact_dir}/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json"
score_path="${artifact_dir}/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json"

fawn_chrome="$(fawn_resolve_chrome_binary)"
doe_lib="$(fawn_resolve_doe_lib)"

if [[ ! -x "${fawn_chrome}" ]]; then
  echo "missing Fawn Chromium binary: ${fawn_chrome}" >&2
  exit 1
fi

if [[ ! -f "${doe_lib}" ]]; then
  echo "missing Doe runtime library: ${doe_lib}" >&2
  exit 1
fi

mkdir -p "${artifact_dir}"

exec "${SCRIPT_DIR}/run-bench.sh" \
  --mode both \
  --dawn-chrome "${fawn_chrome}" \
  --doe-chrome "${fawn_chrome}" \
  --doe-lib "${doe_lib}" \
  --out "${report_path}" \
  --summary-out "${summary_path}" \
  --check-out "${check_path}" \
  --score-out "${score_path}" \
  --require-browser-release-class \
  --required-fawn-release-profile any \
  --mode-schedule paired-balanced \
  --strict-run \
  --iters-upload 180 \
  --iters-dispatch 160 \
  --iters-render 96 \
  --iters-pipeline 256 \
  --iters-async-pipeline 64 \
  --iters-workflow 64 \
  --iters-texture 64 \
  "$@"
