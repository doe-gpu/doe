#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_OUT="${1:-${FAWN_CHROMIUM_RELEASE_SOURCE_OUT:-${LANE_DIR}/src/out/fawn_release}}"
LOCAL_OUT="${2:-${FAWN_CHROMIUM_RELEASE_LOCAL_OUT:-${LANE_DIR}/out/fawn_release_local}}"
APP_ALIAS="${FAWN_CHROMIUM_LOCAL_APP_NAME:-Fawn.app}"

if [[ ! -d "${SOURCE_OUT}" ]]; then
  echo "missing release output directory: ${SOURCE_OUT}" >&2
  exit 1
fi

mkdir -p "${LOCAL_OUT}"
copied_any=0

sync_app_bundle() {
  local src_app=""
  if [[ -d "${SOURCE_OUT}/${APP_ALIAS}" ]]; then
    src_app="${SOURCE_OUT}/${APP_ALIAS}"
  elif [[ -d "${SOURCE_OUT}/Chromium.app" ]]; then
    src_app="${SOURCE_OUT}/Chromium.app"
  fi

  if [[ -z "${src_app}" ]]; then
    return
  fi

  rsync -a --delete "${src_app}/" "${LOCAL_OUT}/${APP_ALIAS}/"
  copied_any=1
}

sync_entry() {
  local rel_path="$1"
  local src_path="${SOURCE_OUT}/${rel_path}"
  if [[ ! -e "${src_path}" ]]; then
    return
  fi
  rsync -a --delete "${src_path}" "${LOCAL_OUT}/"
  copied_any=1
}

sync_app_bundle
sync_entry "args.gn"
sync_entry "fawn-release-build.json"
sync_entry "chrome"
sync_entry "chrome_100_percent.pak"
sync_entry "chrome_200_percent.pak"
sync_entry "chrome_crashpad_handler"
sync_entry "chromedriver"
sync_entry "chrome_sandbox"
sync_entry "locales"
sync_entry "icudtl.dat"
sync_entry "resources.pak"
sync_entry "snapshot_blob.bin"
sync_entry "v8_context_snapshot.bin"

if [[ "${copied_any}" -eq 0 ]]; then
  echo "no known release artifacts found under: ${SOURCE_OUT}" >&2
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" && -d "${LOCAL_OUT}/${APP_ALIAS}" ]]; then
  "${SCRIPT_DIR}/patch-chromium-app-doe.sh" --app "${LOCAL_OUT}/${APP_ALIAS}" || \
    echo "warning: unable to enforce Doe icon/name on local app bundle" >&2
fi

if [[ "$(uname -s)" == "Darwin" && -f "${LOCAL_OUT}/${APP_ALIAS}/Contents/Info.plist" ]]; then
  plist_path="${LOCAL_OUT}/${APP_ALIAS}/Contents/Info.plist"
  if [[ -x "/usr/libexec/PlistBuddy" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Fawn" "${plist_path}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Fawn" "${plist_path}" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Fawn" "${plist_path}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Fawn" "${plist_path}" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Set :CFBundleSpokenName Fawn" "${plist_path}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleSpokenName string Fawn" "${plist_path}" >/dev/null 2>&1
  fi
fi

echo "synced release artifacts to: ${LOCAL_OUT}"
echo "app bundle path: ${LOCAL_OUT}/${APP_ALIAS}"
du -sh "${LOCAL_OUT}" 2>/dev/null || true
