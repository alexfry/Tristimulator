#!/bin/bash
# Debug build and test. Ad-hoc signature only. This script must not read
# Developer ID or App Store Connect secrets.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ci_common.sh
source "${SCRIPT_DIR}/ci_common.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  ci_die "ci_xcode_test.sh must run on macOS."
fi

REPO_ROOT=$(ci_repo_root)
cd "${REPO_ROOT}"

prefix=$(ci_thirdparty_prefix)
work="${RUNNER_TEMP:-$(mktemp -d)}"
derived="${work}/DerivedData"
results="${work}/TestResults"
xcconfig="${work}/ci-test.xcconfig"
entitlements="${work}/ci-test.entitlements"
mkdir -p "${derived}" "${results}"

# Ad-hoc test signature. An empty entitlements file replaces the Developer ID
# entitlements, which an ad-hoc signature will not accept. get-task-allow is
# injected so the test runner can attach. The release script signs for real.
cat > "${entitlements}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
EOF

cat > "${xcconfig}" <<EOF
HEADER_SEARCH_PATHS = ${prefix}/include ${prefix}/include/OpenEXR ${prefix}/include/Imath
HEADER_SEARCH_PATHS[arch=*] = \$(HEADER_SEARCH_PATHS)
LIBRARY_SEARCH_PATHS = ${prefix}/lib
LIBRARY_SEARCH_PATHS[arch=*] = \$(LIBRARY_SEARCH_PATHS)
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
CODE_SIGN_IDENTITY[sdk=macosx*] = -
DEVELOPMENT_TEAM =
CODE_SIGNING_ALLOWED = YES
CODE_SIGNING_REQUIRED = YES
CODE_SIGN_ENTITLEMENTS = ${entitlements}
CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
ENABLE_HARDENED_RUNTIME = NO
ENABLE_APP_SANDBOX = NO
PROVISIONING_PROFILE_SPECIFIER =
EOF
link_flags=$(ci_static_link_flags "${REPO_ROOT}/Generated/ThirdParty.generated.xcconfig")
printf 'OTHER_LDFLAGS = %s\n' "${link_flags}" >> "${xcconfig}"
ci_log "Linking with the generated static library list."

run_xcodebuild test \
  -project Tristimulator.xcodeproj \
  -scheme Tristimulator \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${derived}" \
  -resultBundlePath "${results}/Tristimulator.xcresult" \
  -parallel-testing-enabled NO \
  -xcconfig "${xcconfig}"
