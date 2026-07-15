#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXTERNAL_ENV_FILE="${LANE_DIR}/.external-lane.env"
EXTERNAL_ENV_FILE_LEGACY="${LANE_DIR}/.external-macos.env"

if [[ -f "${EXTERNAL_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${EXTERNAL_ENV_FILE}"
elif [[ -f "${EXTERNAL_ENV_FILE_LEGACY}" ]]; then
  # shellcheck disable=SC1090
  source "${EXTERNAL_ENV_FILE_LEGACY}"
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"

if [[ ! -d "${LANE_DIR}/src" ]]; then
  echo "missing lane src checkout: ${LANE_DIR}/src" >&2
  echo "run fetch/gclient sync first." >&2
  exit 1
fi

cd "${LANE_DIR}/src"

LOCAL_RELEASE_GN_ARGS="is_debug=false is_official_build=false dcheck_always_on=false chrome_pgo_phase=0 symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 is_chrome_for_testing=false is_chrome_for_testing_branded=false is_chrome_branded=false use_clang_modules=false"
OFFICIAL_RELEASE_GN_ARGS="is_debug=false is_official_build=true dcheck_always_on=false chrome_pgo_phase=0 symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 is_chrome_for_testing=false is_chrome_for_testing_branded=false is_chrome_branded=false use_clang_modules=false"
release_profile="${FAWN_CHROMIUM_RELEASE_PROFILE:-official}"
autoninja_args=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --official)
      release_profile="official"
      shift
      ;;
    --release-profile)
      if [[ "$#" -lt 2 ]]; then
        echo "missing value for --release-profile" >&2
        exit 2
      fi
      release_profile="$2"
      shift 2
      ;;
    *)
      autoninja_args+=("$1")
      shift
      ;;
  esac
done

has_local_jobs_arg=false
if [[ "${#autoninja_args[@]}" -gt 0 ]]; then
  for arg in "${autoninja_args[@]}"; do
    case "${arg}" in
      -local_jobs|--local_jobs|-local_jobs=*|--local_jobs=*|-j*)
        has_local_jobs_arg=true
        ;;
    esac
  done
fi

if [[ -n "${FAWN_CHROMIUM_LOCAL_JOBS:-}" && "${has_local_jobs_arg}" == false ]]; then
  if [[ ! "${FAWN_CHROMIUM_LOCAL_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "invalid FAWN_CHROMIUM_LOCAL_JOBS: ${FAWN_CHROMIUM_LOCAL_JOBS}" >&2
    exit 2
  fi
  autoninja_args+=("-local_jobs" "${FAWN_CHROMIUM_LOCAL_JOBS}")
fi

case "${release_profile}" in
  local)
    DEFAULT_RELEASE_GN_ARGS="${LOCAL_RELEASE_GN_ARGS}"
    ;;
  official)
    DEFAULT_RELEASE_GN_ARGS="${OFFICIAL_RELEASE_GN_ARGS}"
    ;;
  *)
    echo "unknown release profile: ${release_profile}" >&2
    exit 2
    ;;
esac

RELEASE_GN_ARGS="${FAWN_CHROMIUM_RELEASE_GN_ARGS:-${DEFAULT_RELEASE_GN_ARGS}}"
gn gen out/fawn_release "--args=${RELEASE_GN_ARGS}"

if [[ "${#autoninja_args[@]}" -gt 0 ]]; then
  autoninja -C out/fawn_release chrome "${autoninja_args[@]}"
else
  autoninja -C out/fawn_release chrome
fi

args_sha256="$(shasum -a 256 out/fawn_release/args.gn | awk '{print $1}')"
cat > out/fawn_release/fawn-release-build.json <<EOF
{"target":"chrome","releaseProfile":"${release_profile}","argsSha256":"${args_sha256}"}
EOF

MACOS_APP="${SCRIPT_DIR}/../src/out/fawn_release/Chromium.app"
if [[ "$(uname -s)" == "Darwin" && -x "${MACOS_APP}/Contents/MacOS/Chromium" ]]; then
  "${SCRIPT_DIR}/patch-chromium-app-doe.sh" --app "${MACOS_APP}" || \
    echo "warning: unable to patch app default runtime flags" >&2
fi

"${SCRIPT_DIR}/sync-release-artifacts-local.sh" "out/fawn_release"

if [[ "$(uname -s)" == "Darwin" ]]; then
  LOCAL_OUT="${FAWN_CHROMIUM_RELEASE_LOCAL_OUT:-${LANE_DIR}/out/fawn_release_local}"
  LOCAL_APP_NAME="${FAWN_CHROMIUM_LOCAL_APP_NAME:-Fawn.app}"
  LOCAL_APP_PATH="${LOCAL_OUT}/${LOCAL_APP_NAME}"
  HOST_APP_PATH="${FAWN_CHROMIUM_HOST_APP_PATH:-${HOME}/Applications/Fawn.app}"

  if [[ -d "${LOCAL_APP_PATH}" ]]; then
    mkdir -p "$(dirname "${HOST_APP_PATH}")"
    rsync -a --delete "${LOCAL_APP_PATH}/" "${HOST_APP_PATH}/"
    "${SCRIPT_DIR}/patch-chromium-app-doe.sh" --app "${HOST_APP_PATH}" || \
      echo "warning: unable to enforce Doe icon/name on host app copy" >&2
    echo "copied app bundle to host path: ${HOST_APP_PATH}"
  else
    echo "local app copy skipped; missing: ${LOCAL_APP_PATH}" >&2
  fi
fi
