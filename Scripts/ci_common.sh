#!/bin/bash
# Shared helpers for the macOS GitHub Actions scripts. Source this file.

ci_log() {
  printf '[ci] %s\n' "$*" >&2
}

ci_die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# Directory containing this file is Scripts/, so the repo root is its parent.
ci_repo_root() {
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  (cd "${here}/.." && pwd)
}

# Prefix produced by Scripts/build_thirdparty.sh for the arm64-osx-tristimulator triplet.
ci_thirdparty_prefix() {
  local root
  root="${THIRDPARTY_ROOT:-${HOME}/Library/Caches/Tristimulator/ThirdParty}"
  printf '%s\n' "${root}/installed/arm64-osx-tristimulator"
}

# Link flags for every static archive vcpkg installed.
# project.pbxproj hardcodes a subset. The first CI link failed with undefined
# BZ2_*, ZSTD_*, and lzma_* symbols from libminizip-ng and libtiff. Those
# archives are in the install prefix and in Generated/ThirdParty.generated.xcconfig.
# -lcompression and -liconv stay because they come from the SDK, not from a .a.
ci_static_link_flags() {
  local generated="$1"
  local line
  if [[ ! -f "${generated}" ]]; then
    ci_die "Missing ${generated}. Scripts/build_thirdparty.sh writes this after vcpkg install."
  fi
  line=$(grep '^OTHER_LDFLAGS' "${generated}" | head -n 1)
  if [[ -z "${line}" ]]; then
    ci_die "${generated} has no OTHER_LDFLAGS line."
  fi
  line=${line#"OTHER_LDFLAGS = "}
  line=${line//\$(inherited)/}
  case " ${line} " in
    *" -lcompression "*) ;;
    *) line="${line} -lcompression" ;;
  esac
  case " ${line} " in
    *" -liconv "*) ;;
    *) line="${line} -liconv" ;;
  esac
  printf '%s\n' "${line}"
}

# xcbeautify is on the GitHub macOS image. pipefail in the caller preserves
# xcodebuild's status when the log is piped.
run_xcodebuild() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "$@" | xcbeautify
  else
    xcodebuild "$@"
  fi
}
