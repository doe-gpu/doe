#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LANE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAWN_PROJECT_ROOT="${FAWN_REPO_ROOT:-${REPO_ROOT}}"
if [[ ! -d "${FAWN_PROJECT_ROOT}/zig" ]]; then
  ALT_ROOT="$(cd "${FAWN_PROJECT_ROOT}/.." && pwd)"
  if [[ -d "${ALT_ROOT}/zig" ]]; then
    FAWN_PROJECT_ROOT="${ALT_ROOT}"
  fi
fi

usage() {
  cat <<'EOF'
Usage:
  ./scripts/patch-chromium-app-doe.sh --app PATH [--doe-lib PATH] [--app-name NAME] [--force]

Patches a Chromium.app bundle so direct launch defaults to:
  --use-webgpu-runtime=doe
  --doe-webgpu-library-path=<resolved lib>

The script renames the original binary to `Chromium-real` and installs
an executable wrapper at `Contents/MacOS/Chromium`.

It also updates bundle metadata so the app displays as `Fawn` by default and
forces the dock icon from the canonical Fawn icon asset.
EOF
}

fawn_default_doe_lib() {
  local ext="dylib"
  printf "%s\n" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe_full.${ext}" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe_full.so" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe_full.dll" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe.${ext}" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe.so" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe.dylib" \
    "${FAWN_PROJECT_ROOT}/runtime/zig/zig-out/lib/libwebgpu_doe.dll"
}

fawn_default_doe_icon_path() {
  printf "%s\n" "${LANE_ROOT}/assets/logo/source/fawn-icon-main.svg"
}

fawn_default_doe_compiled_icns() {
  printf "%s\n" "${LANE_ROOT}/assets/logo/compiled/macos/fawn-icon-main.icns"
}

fawn_default_doe_lib_name() {
  local source="$1"
  local ext
  ext="$(printf '%s' "${source##*.}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${ext}" == "svg" ]]; then
    echo "fawn-icon-main.icns"
    return 0
  fi
  echo "$(basename "${source}")"
}

fawn_convert_svg_to_icns() {
  local svg_path="$1"
  local out_icns="$2"
  local work_dir
  local iconset_dir

  work_dir="$(mktemp -d)"
  iconset_dir="${work_dir}/fawn.iconset"
  mkdir -p "${iconset_dir}"

  # Keep a single temporary root for cleanup regardless of conversion path.
  TMP_ICON_WORK="${work_dir}"

  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_16x16.png" --resampleHeightWidthMax 16 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_16x16@2x.png" --resampleHeightWidthMax 32 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_32x32.png" --resampleHeightWidthMax 32 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_32x32@2x.png" --resampleHeightWidthMax 64 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_64x64.png" --resampleHeightWidthMax 64 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_64x64@2x.png" --resampleHeightWidthMax 128 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_128x128.png" --resampleHeightWidthMax 128 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_128x128@2x.png" --resampleHeightWidthMax 256 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_256x256.png" --resampleHeightWidthMax 256 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_256x256@2x.png" --resampleHeightWidthMax 512 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_512x512.png" --resampleHeightWidthMax 512 >/dev/null
  sips --setProperty format png "${svg_path}" --out "${iconset_dir}/icon_512x512@2x.png" --resampleHeightWidthMax 1024 >/dev/null

  iconutil -c icns "${iconset_dir}" -o "${out_icns}"
}

APP_PATH=""
DOE_LIB="${FAWN_DOE_LIB:-}"
APP_NAME="${FAWN_APP_NAME:-Fawn}"
APP_ICON="${FAWN_APP_ICON:-}"
FORCE=0
TMP_ICON_WORK=""
CANONICAL_APP_ICON="$(fawn_default_doe_icon_path)"

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
      DOE_LIB="$2"
      shift 2
      ;;
    --app-name)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --app-name" >&2
        exit 2
      fi
      APP_NAME="$2"
      shift 2
      ;;
    --force)
      FORCE=1
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

if [[ -z "${APP_PATH}" ]]; then
  echo "--app is required" >&2
  usage
  exit 2
fi

trap '[[ -n "${TMP_ICON_WORK}" ]] && rm -rf "${TMP_ICON_WORK}"' EXIT

if [[ ! -d "${APP_PATH}" ]]; then
  echo "missing app bundle: ${APP_PATH}" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Mac-only operation (darwin only)" >&2
  exit 1
fi

if [[ -z "${DOE_LIB}" ]]; then
  while IFS= read -r candidate; do
    if [[ -f "${candidate}" ]]; then
      DOE_LIB="${candidate}"
      break
    fi
  done < <(fawn_default_doe_lib)
fi

if [[ -z "${DOE_LIB}" || ! -f "${DOE_LIB}" ]]; then
  echo "missing libwebgpu_doe path; set --doe-lib or FAWN_DOE_LIB" >&2
  exit 1
fi

MACOS_BIN="${APP_PATH}/Contents/MacOS/Chromium"
REAL_BIN="${MACOS_BIN}-real"
WRAPPER_MARKER="${MACOS_BIN}.fawn-doe-wrapped"

is_fawn_doe_wrapper() {
  local binary_path="$1"
  [[ -f "${binary_path}" ]] \
    && grep -Fq 'REAL_BINARY="${SCRIPT_DIR}/Chromium-real"' "${binary_path}"
}

if [[ ! -x "${MACOS_BIN}" ]]; then
  echo "missing executable: ${MACOS_BIN}" >&2
  exit 1
fi

current_is_wrapper=0
if is_fawn_doe_wrapper "${MACOS_BIN}"; then
  current_is_wrapper=1
fi

write_wrapper=0
if [[ "${current_is_wrapper}" -eq 1 ]]; then
  if [[ ! -f "${REAL_BIN}" ]]; then
    echo "wrapped app is missing real binary: ${REAL_BIN}" >&2
    exit 1
  fi
  if [[ "${FORCE}" -eq 1 ]]; then
    write_wrapper=1
  else
    echo "already wrapped: ${MACOS_BIN}"
  fi
else
  if [[ -f "${REAL_BIN}" ]]; then
    echo "refreshing relinked Chromium binary: ${REAL_BIN}"
  fi
  mv -f "${MACOS_BIN}" "${REAL_BIN}"
  write_wrapper=1
fi

if [[ "${write_wrapper}" -eq 1 ]]; then

  cat > "${MACOS_BIN}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
REAL_BINARY="\${SCRIPT_DIR}/Chromium-real"
DOE_LIB="${DOE_LIB}"

if [[ -n "\${FAWN_DOE_LIB:-}" ]]; then
  DOE_LIB="\${FAWN_DOE_LIB}"
fi

if [[ ! -x "\${REAL_BINARY}" ]]; then
  echo "missing real Chromium binary: \${REAL_BINARY}" >&2
  exit 1
fi

if [[ -z "\${DOE_LIB}" || ! -f "\${DOE_LIB}" ]]; then
  echo "missing libwebgpu_doe runtime: \${DOE_LIB}" >&2
  exit 1
fi

FAWN_START="\${SCRIPT_DIR}/../Resources/fawn-start.html"

exec -a fawn-doe "\${REAL_BINARY}" \
  --use-webgpu-runtime=doe \
  --doe-webgpu-library-path="\${DOE_LIB}" \
  --no-first-run \
  --homepage="file://\${FAWN_START}" \
  --new-window "file://\${FAWN_START}" \
  "\$@"
EOF
  chmod 0755 "${MACOS_BIN}"
fi
touch "${WRAPPER_MARKER}"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
RESOURCES_DIR="${APP_PATH}/Contents/Resources"

if [[ -x "/usr/libexec/PlistBuddy" && -f "${INFO_PLIST}" ]]; then
  if [[ -n "${APP_NAME}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${INFO_PLIST}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "${INFO_PLIST}" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "${INFO_PLIST}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "${INFO_PLIST}" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Set :CFBundleSpokenName ${APP_NAME}" "${INFO_PLIST}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleSpokenName string ${APP_NAME}" "${INFO_PLIST}" >/dev/null 2>&1
  fi
fi

if [[ -z "${APP_ICON}" ]]; then
  APP_ICON="${CANONICAL_APP_ICON}"
fi

if [[ "${APP_ICON}" != "${CANONICAL_APP_ICON}" ]]; then
  echo "error: app icon is fixed for this lane; expected ${CANONICAL_APP_ICON}" >&2
  echo "  provided: ${APP_ICON}" >&2
  exit 1
fi

if [[ ! -f "${APP_ICON}" ]]; then
  echo "missing app icon path: ${APP_ICON}" >&2
  exit 1
fi

if [[ -n "${APP_ICON}" && -f "${APP_ICON}" ]]; then
  APP_ICON_NAME="$(fawn_default_doe_lib_name "${APP_ICON}")"
  APP_ICON_EXT="$(printf '%s' "${APP_ICON##*.}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${APP_ICON_EXT}" == "svg" ]]; then
    APP_ICON_PATH="${RESOURCES_DIR}/${APP_ICON_NAME}"
    if [[ "${APP_ICON}" == "${CANONICAL_APP_ICON}" ]]; then
      PRECOMPILED_APP_ICON="$(fawn_default_doe_compiled_icns)"
      if [[ -f "${PRECOMPILED_APP_ICON}" ]]; then
        APP_ICON_PATH="${PRECOMPILED_APP_ICON}"
      else
        fawn_convert_svg_to_icns "${APP_ICON}" "${RESOURCES_DIR}/${APP_ICON_NAME}"
        APP_ICON_PATH="${RESOURCES_DIR}/${APP_ICON_NAME}"
      fi
    else
      fawn_convert_svg_to_icns "${APP_ICON}" "${RESOURCES_DIR}/${APP_ICON_NAME}"
    fi
  else
    APP_ICON_PATH="${APP_ICON}"
  fi

  if [[ -d "${RESOURCES_DIR}" ]]; then
    cp -f "${APP_ICON_PATH}" "${RESOURCES_DIR}/app.icns"
    if [[ -x "/usr/libexec/PlistBuddy" ]]; then
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "${INFO_PLIST}" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile app.icns" "${INFO_PLIST}" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string app.icns" "${INFO_PLIST}" >/dev/null 2>&1
    fi
  else
    echo "missing resources dir: ${RESOURCES_DIR}" >&2
  fi
else
  if [[ -n "${APP_ICON}" && ! -f "${APP_ICON}" ]]; then
    echo "warning: provided app icon not found: ${APP_ICON}" >&2
  fi
fi

if [[ -d "${RESOURCES_DIR}" ]]; then
  for RESOURCE_SRC in "${LANE_ROOT}"/resources/fawn-*.html; do
    if [[ -f "${RESOURCE_SRC}" ]]; then
      cp -f "${RESOURCE_SRC}" "${RESOURCES_DIR}/$(basename "${RESOURCE_SRC}")"
    fi
  done
fi

echo "patched app bundle: ${APP_PATH}"
echo "runtime default: --use-webgpu-runtime=doe --doe-webgpu-library-path=${DOE_LIB}"
if [[ -n "${APP_NAME}" ]]; then
  echo "app name: ${APP_NAME}"
fi
if [[ -f "${RESOURCES_DIR}/app.icns" ]]; then
  echo "app icon: ${APP_ICON:-auto-discovered}"
fi
