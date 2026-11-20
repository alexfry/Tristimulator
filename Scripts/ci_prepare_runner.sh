#!/bin/bash
# Select the Xcode that can compile this repo, and make the vcpkg prefix
# visible at the absolute path baked into the Xcode project.
#
# TristimulatorQuickLook sets MACOSX_DEPLOYMENT_TARGET = 26.4, so the SDK must
# be 26.4 or newer. The app icon (Tristimulator/NewIcon2_v005.icon) was saved by
# Icon Composer in Xcode 27 and uses settings (group refractivity, features,
# fill-specializations) that crash Xcode 26.6's actool. The xcode-27 runner
# image (macOS 27, image 20261104.0337.1) ships Xcode 27.2 (build 27B52) at
# /Applications/Xcode_27.2.app, matching the Xcode used to author the icon.
# Pin it explicitly so the image default (27.1) cannot change the compiler.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ci_common.sh
source "${SCRIPT_DIR}/ci_common.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  ci_die "ci_prepare_runner.sh must run on macOS."
fi

XCODE_APP="/Applications/Xcode_27.2.app"
DEV_DIR="${XCODE_APP}/Contents/Developer"

if [[ ! -d "${XCODE_APP}" ]]; then
  ci_log "Xcode applications on this machine:"
  ls -d /Applications/Xcode*.app >&2 || true
  ci_die "Xcode 27.2 is not installed at ${XCODE_APP}. The Icon Composer app icon uses Xcode 27 settings and needs the Xcode 27.2 app from the xcode-27 runner image."
fi

sudo xcode-select -s "${XCODE_APP}"
export DEVELOPER_DIR="${DEV_DIR}"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'DEVELOPER_DIR=%s\n' "${DEV_DIR}" >> "${GITHUB_ENV}"
fi

xcodebuild -version
sdk_ver=$(xcrun --sdk macosx --show-sdk-version)
ci_log "macOS SDK ${sdk_ver}"
SDK_VER="${sdk_ver}" python3 - <<'PY'
import os, sys
raw = os.environ["SDK_VER"]
parts = tuple(int(p) for p in raw.split("."))
if parts < (26, 4):
    sys.stderr.write("macOS SDK %s is older than 26.4, so TristimulatorQuickLook will not compile.\n" % raw)
    sys.exit(1)
PY

# The standard macos-26 runner is a 3-core M1 with a small disk. Other Xcode
# copies and the Android SDK are unused here. Only delete them when free space
# is actually tight, so a roomy image does not spend minutes on rm.
avail_kb=$(df -k / | awk 'NR==2 { print $4 }')
ci_log "free disk before cleanup: ${avail_kb:-unknown} KiB"
df -h /
threshold_kb=20971520 # 20 GiB
if [[ -n "${avail_kb}" && "${avail_kb}" -lt "${threshold_kb}" ]]; then
  ci_log "Free disk is under 20 GiB. Removing unused Xcode copies and Android SDK files."
  shopt -s nullglob
  for app in /Applications/Xcode_*.app; do
    base=$(basename "${app}")
    case "${base}" in
      Xcode_27.2.app | Xcode_27.2.0.app) continue ;;
    esac
    # Symlinks are unlinked. The selected Xcode_27.2.app is skipped above,
    # so a symlink that points at it is not followed into that app.
    sudo rm -rf "${app}"
  done
  shopt -u nullglob
  sudo rm -rf \
    "${HOME}/Library/Android" \
    "${HOME}/Library/Developer/CoreSimulator/Caches" \
    /Users/runner/Library/Android
  ci_log "free disk after cleanup:"
  df -h /
else
  ci_log "Free disk is at least 20 GiB. Leaving other Xcode copies in place."
fi

# project.pbxproj still points HEADER_SEARCH_PATHS and LIBRARY_SEARCH_PATHS at
# /Users/alex/Library/Caches/Tristimulator/... and does not use ThirdParty.xcconfig
# as a base configuration. build_thirdparty.sh installs under $HOME. A symlink
# makes those baked paths resolve for the runner user. xcodebuild -xcconfig
# also sets the same paths, in case a conditional setting still wins.
cache="${HOME}/Library/Caches/Tristimulator"
mkdir -p "${cache}"
expected="/Users/alex/Library/Caches/Tristimulator"
if [[ "${expected}" != "${cache}" ]]; then
  sudo mkdir -p "$(dirname "${expected}")"
  sudo ln -sfn "${cache}" "${expected}"
fi
if [[ ! -d "${expected}" ]]; then
  ci_die "Could not alias ${expected} to ${cache}."
fi

ci_log "Using ${XCODE_APP} ($(xcodebuild -version | tr '\n' ' '))"
