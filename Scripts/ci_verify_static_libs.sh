#!/bin/bash
# Fail before xcodebuild if the Tristimulator target's -l flags do not match the
# static libraries vcpkg just installed. The names live in project.pbxproj
# (ThirdParty.xcconfig is not the target base configuration). System libraries
# that are not part of the vcpkg prefix are skipped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ci_common.sh
source "${SCRIPT_DIR}/ci_common.sh"

REPO_ROOT=$(ci_repo_root)
cd "${REPO_ROOT}"

prefix=$(ci_thirdparty_prefix)
lib_dir="${prefix}/lib"
pbx="${REPO_ROOT}/Tristimulator.xcodeproj/project.pbxproj"

if [[ ! -d "${lib_dir}" ]]; then
  ci_die "vcpkg install prefix is missing: ${lib_dir}"
fi
if [[ ! -f "${pbx}" ]]; then
  ci_die "Xcode project is missing: ${pbx}"
fi

names=$(python3 - "${pbx}" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
seen = []
for name in re.findall(r'"-l([^"]+)"', text):
    if name not in seen:
        seen.append(name)
sys.stdout.write("\n".join(seen))
PY
)

missing=0
checked=0
# c++, iconv, and compression come from the SDK, not the vcpkg prefix.
system_libs=" c++ iconv compression "
while IFS= read -r name; do
  [[ -z "${name}" ]] && continue
  case "${system_libs}" in
    *" ${name} "*) continue ;;
  esac
  checked=$((checked + 1))
  if [[ ! -e "${lib_dir}/lib${name}.a" && ! -e "${lib_dir}/lib${name}.dylib" ]]; then
    printf '::error::-l%s has no lib%s.a under %s\n' "${name}" "${name}" "${lib_dir}" >&2
    missing=1
  fi
done <<EOF
${names}
EOF

if [[ "${missing}" -ne 0 ]]; then
  ci_log "Libraries in ${lib_dir}:"
  ls -1 "${lib_dir}" >&2 || true
  ci_die "The Xcode link line does not match this vcpkg install. Library names such as -lOpenEXR-3_4 are hardcoded in the Tristimulator target."
fi

if [[ "${checked}" -eq 0 ]]; then
  ci_die "No -l flags were found in ${pbx}."
fi

ci_log "All ${checked} vcpkg libraries named by the Xcode project are in ${lib_dir}."
