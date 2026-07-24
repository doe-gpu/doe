#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lane-paths.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/refresh-doe-app.sh [--app PATH] [--doe-lib PATH] [--optimize MODE] [--skip-build]

Rebuilds the full Doe drop-in library and reapplies the Chromium.app/Fawn.app
wrapper so direct macOS launches use the latest Doe runtime by default.
EOF
}

resolve_default_app_bundle() {
  local release_local_out
  release_local_out="${FAWN_CHROMIUM_RELEASE_LOCAL_OUT:-${FAWN_CHROMIUM_LANE_DIR}/out/fawn_release_local}"
  local candidates=(
    "${release_local_out}/Fawn.app"
    "${release_local_out}/Chromium.app"
    "${HOME}/Applications/Fawn.app"
    "${FAWN_CHROMIUM_LANE_DIR}/src/out/fawn_release/Fawn.app"
    "${FAWN_CHROMIUM_LANE_DIR}/src/out/fawn_release/Chromium.app"
    "${FAWN_REPO_ROOT}/browser/chromium_webgpu_lane/out/fawn_release_local/Fawn.app"
    "${FAWN_REPO_ROOT}/browser/chromium_webgpu_lane/out/fawn_release_local/Chromium.app"
    "${FAWN_REPO_ROOT}/browser/chromium_webgpu_lane/src/out/fawn_release/Fawn.app"
    "${FAWN_REPO_ROOT}/browser/chromium_webgpu_lane/src/out/fawn_release/Chromium.app"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  echo "${candidates[0]}"
}

APP_PATH=""
DOE_LIB_OVERRIDE=""
OPTIMIZE_MODE="ReleaseFast"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --app" >&2
        exit 2
      fi
      APP_PATH="$2"
      shift 2
      ;;
    --doe-lib)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --doe-lib" >&2
        exit 2
      fi
      DOE_LIB_OVERRIDE="$2"
      shift 2
      ;;
    --optimize)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --optimize" >&2
        exit 2
      fi
      OPTIMIZE_MODE="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$(fawn_host_os)" != "darwin" ]]; then
  echo "refresh-doe-app.sh is macOS-only" >&2
  exit 1
fi

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  (
    cd "${FAWN_REPO_ROOT}/runtime/zig"
    zig build dropin-full "-Doptimize=${OPTIMIZE_MODE}"
  )
fi

DOE_LIB="$(fawn_resolve_doe_lib "${DOE_LIB_OVERRIDE}")"
if [[ ! -f "${DOE_LIB}" ]]; then
  echo "missing Doe runtime library: ${DOE_LIB}" >&2
  exit 1
fi

if [[ -z "${APP_PATH}" ]]; then
  APP_PATH="$(resolve_default_app_bundle)"
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "missing app bundle: ${APP_PATH}" >&2
  exit 1
fi

"${SCRIPT_DIR}/patch-chromium-app-doe.sh" --app "${APP_PATH}" --doe-lib "${DOE_LIB}" --force

echo "refreshed Doe Chromium app"
echo "app: ${APP_PATH}"
echo "doe-lib: ${DOE_LIB}"
