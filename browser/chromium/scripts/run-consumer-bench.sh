#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lane-paths.sh"

stock_chrome_candidates() {
  printf "%s\n" \
    "${FAWN_STOCK_CHROME_BIN:-}" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary" \
    "/usr/bin/google-chrome-stable" \
    "/usr/bin/google-chrome" \
    "/usr/bin/chromium" \
    "/usr/bin/chromium-browser"
}

resolve_stock_chrome() {
  local candidate
  while IFS= read -r candidate; do
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done < <(stock_chrome_candidates)

  echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
artifact_dir="${FAWN_CONSUMER_BENCH_OUT_DIR:-${FAWN_REPO_ROOT}/browser/chromium/artifacts/${timestamp}}"
report_path="${artifact_dir}/chrome-vs-fawn.browser-layered.superset.diagnostic.json"
summary_path="${artifact_dir}/chrome-vs-fawn.browser-layered.superset.summary.json"
check_path="${artifact_dir}/chrome-vs-fawn.browser-layered.superset.check.json"
score_path="${artifact_dir}/chrome-vs-fawn.browser-layered.superset.score.json"

stock_chrome="$(resolve_stock_chrome)"
fawn_chrome="$(fawn_resolve_chrome_binary)"
doe_lib="$(fawn_resolve_doe_lib)"
required_fawn_release_profile="${FAWN_CONSUMER_REQUIRED_FAWN_RELEASE_PROFILE:-official}"

if [[ ! -x "${stock_chrome}" ]]; then
  echo "missing stock Chrome binary: ${stock_chrome}" >&2
  exit 1
fi

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
  --dawn-chrome "${stock_chrome}" \
  --doe-chrome "${fawn_chrome}" \
  --doe-lib "${doe_lib}" \
  --out "${report_path}" \
  --summary-out "${summary_path}" \
  --check-out "${check_path}" \
  --score-out "${score_path}" \
  --require-browser-release-class \
  --required-fawn-release-profile "${required_fawn_release_profile}" \
  --iters-upload 180 \
  --iters-dispatch 160 \
  --iters-render 96 \
  --iters-pipeline 256 \
  --iters-async-pipeline 64 \
  --iters-workflow 64 \
  --iters-texture 64 \
  "$@"
