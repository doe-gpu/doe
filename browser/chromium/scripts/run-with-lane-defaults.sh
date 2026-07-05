#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lane-paths.sh"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <smoke|bench> [args...]" >&2
  exit 2
fi

runner="$1"
shift

chrome_bin="$(fawn_resolve_chrome_binary)"
dawn_chrome_bin=""
doe_chrome_bin=""
doe_lib="$(fawn_resolve_doe_lib)"
mode="both"
skip_run=0
forward_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chrome)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --chrome" >&2
        exit 2
      fi
      chrome_bin="$2"
      forward_args+=("$1" "$2")
      shift 2
      ;;
    --doe-lib)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --doe-lib" >&2
        exit 2
      fi
      doe_lib="$2"
      forward_args+=("$1" "$2")
      shift 2
      ;;
    --dawn-chrome)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --dawn-chrome" >&2
        exit 2
      fi
      dawn_chrome_bin="$2"
      forward_args+=("$1" "$2")
      shift 2
      ;;
    --doe-chrome)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --doe-chrome" >&2
        exit 2
      fi
      doe_chrome_bin="$2"
      forward_args+=("$1" "$2")
      shift 2
      ;;
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --mode" >&2
        exit 2
      fi
      mode="$2"
      forward_args+=("$1" "$2")
      shift 2
      ;;
    --skip-run)
      if [[ "${runner}" != "bench" ]]; then
        echo "--skip-run is only supported for bench mode" >&2
        exit 2
      fi
      skip_run=1
      forward_args+=("$1")
      shift
      ;;
    --help|-h)
      if [[ "${runner}" == "smoke" ]]; then
        cat <<'EOF'
Usage:
  ./scripts/run-smoke.sh [webgpu-playwright-smoke args...]

Runs webgpu-playwright-smoke.mjs with host-resolved default --chrome and --doe-lib.
All unrecognized args are forwarded to the Node runner.
EOF
      elif [[ "${runner}" == "bench" ]]; then
        cat <<'EOF'
Usage:
  ./scripts/run-bench.sh [run-browser-benchmark-superset args...]

Runs run-browser-benchmark-superset.py with host-resolved default --chrome and --doe-lib.
For bench mode, you can override browser executable per runtime mode with
--dawn-chrome and --doe-chrome.
All unrecognized args are forwarded to the Python runner.
EOF
      else
        echo "unknown runner: ${runner} (expected smoke|bench)" >&2
        exit 2
      fi
      exit 0
      ;;
    *)
      forward_args+=("$1")
      shift
      ;;
  esac
done

if [[ "${skip_run}" -eq 0 ]]; then
  if [[ "${runner}" == "bench" ]]; then
    dawn_bin_resolved="${dawn_chrome_bin:-${chrome_bin}}"
    doe_bin_resolved="${doe_chrome_bin:-${chrome_bin}}"
    if [[ "${mode}" == "dawn" || "${mode}" == "both" ]]; then
      if [[ ! -x "${dawn_bin_resolved}" ]]; then
      echo "missing dawn mode chrome binary: ${dawn_bin_resolved}" >&2
      exit 1
      fi
    fi
    if [[ "${mode}" == "doe" || "${mode}" == "both" ]]; then
      if [[ ! -x "${doe_bin_resolved}" ]]; then
      echo "missing doe mode chrome binary: ${doe_bin_resolved}" >&2
      exit 1
      fi
    fi
  else
    if [[ ! -x "${chrome_bin}" ]]; then
      echo "missing chrome binary: ${chrome_bin}" >&2
      exit 1
    fi
  fi
  if [[ ("${mode}" == "doe" || "${mode}" == "both") && ! -f "${doe_lib}" ]]; then
    echo "missing doe runtime library: ${doe_lib}" >&2
    exit 1
  fi
fi

if [[ -z "${FAWN_BACKEND_LANE:-}" ]]; then
  case "$(uname -s)" in
    Darwin)
      export FAWN_BACKEND_LANE="metal_doe_app"
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      export FAWN_BACKEND_LANE="d3d12_doe_app"
      ;;
    *)
      export FAWN_BACKEND_LANE="vulkan_doe_app"
      ;;
  esac
fi

if [[ "${runner}" == "smoke" ]]; then
  exec node "${SCRIPT_DIR}/webgpu-playwright-smoke.mjs" \
    --chrome "${chrome_bin}" \
    --doe-lib "${doe_lib}" \
    "${forward_args[@]}"
fi

if [[ "${runner}" == "bench" ]]; then
  exec python3 "${SCRIPT_DIR}/run-browser-benchmark-superset.py" \
    --chrome "${chrome_bin}" \
    --doe-lib "${doe_lib}" \
    "${forward_args[@]}"
fi

echo "unknown runner: ${runner} (expected smoke|bench)" >&2
exit 2
