#!/bin/bash
# Archive Tristimulator, sign the app plus any nested frameworks, dylibs, and the
# Quick Look extension with Developer ID Application and the hardened runtime,
# then put that app in a DMG, notarize the DMG, and staple the DMG.
# The app itself is not submitted to notarytool, so it is not stapled separately.
#
# Stapling retries while Gatekeeper cannot see the ticket yet. A local trust
# rejection stops immediately. If stapling still fails, the notarized DMG is
# kept so the release workflow can upload it to a draft marked unstapled.
#
# Requires the third-party prefix from Scripts/build_thirdparty.sh and the
# secrets checked by Scripts/ci_check_release_secrets.sh. Secrets stay in the
# environment. They are not printed and they are not passed as process arguments
# except for the keychain and p12 passwords, which `security` only accepts as
# flags. The temporary keychain and the decoded files are deleted on exit.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ci_common.sh
source "${SCRIPT_DIR}/ci_common.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  ci_die "ci_release_package.sh must run on macOS."
fi

"${SCRIPT_DIR}/ci_check_release_secrets.sh"

tag="${RELEASE_TAG:-}"
if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z]+)*$ ]]; then
  ci_die "RELEASE_TAG must look like v1.2.3 or v1.2.3-rc1."
fi

marketing=""
if [[ "${tag}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  marketing="${BASH_REMATCH[1]}"
fi

REPO_ROOT=$(ci_repo_root)
cd "${REPO_ROOT}"

prefix=$(ci_thirdparty_prefix)
if [[ ! -d "${prefix}/lib" ]]; then
  ci_die "vcpkg prefix is missing at ${prefix}. Run Scripts/build_thirdparty.sh first."
fi

umask 077
work="${RUNNER_TEMP:-$(mktemp -d)}/tristimulator-release"
mkdir -p "${work}"
KEYCHAIN="${work}/signing.keychain-db"
P12_PATH="${work}/developer-id.p12"
P8_PATH="${work}/AuthKey.p8"
archive="${work}/Tristimulator.xcarchive"
stage="${work}/dmg-stage"
dmg="${work}/Tristimulator-${tag}.dmg"
xcconfig="${work}/release.xcconfig"

cleanup() {
  if [[ -n "${KEYCHAIN:-}" ]]; then
    security delete-keychain "${KEYCHAIN}" >/dev/null 2>&1 || true
  fi
  rm -f "${P12_PATH:-}" "${P8_PATH:-}"
}
trap cleanup EXIT

decode_base64() {
  local dest="$1"
  # macOS base64 is BSD. -D decodes. Line-wrapped secrets are accepted.
  if ! base64 -D > "${dest}"; then
    ci_die "base64 decode failed while writing ${dest##*/}. On a Mac, encode with: base64 -i <file> | pbcopy"
  fi
  if [[ ! -s "${dest}" ]]; then
    ci_die "Decoded ${dest##*/} is empty."
  fi
}

printf '%s' "${DEVELOPER_ID_CERT_P12_BASE64}" | decode_base64 "${P12_PATH}"
printf '%s' "${ASC_KEY_P8_BASE64}" | decode_base64 "${P8_PATH}"

p8_header=$(head -n 1 "${P8_PATH}")
case "${p8_header}" in
  "-----BEGIN "*) ;;
  *) ci_die "ASC_KEY_P8_BASE64 did not decode to a PEM private key. Encode the downloaded AuthKey_*.p8 with: base64 -i AuthKey.p8 | pbcopy" ;;
esac
chmod 600 "${P12_PATH}" "${P8_PATH}"

# Apple Root CA - G3 is already in System Roots on the macos-26 runner.
# Do not download it and do not call `security add-trusted-cert` on it or on
# the WWDR / Developer ID intermediates. add-trusted-cert writes Admin trust
# settings. Custom trust on that root, or a second copy of it beside the
# System Roots copy, makes stapler fail with Error 65 ("Could not validate
# ticket") in a fraction of a second. That is local trust evaluation.
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security set-keychain-settings -lut 21600 "${KEYCHAIN}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
if ! security import "${P12_PATH}" \
  -k "${KEYCHAIN}" \
  -P "${DEVELOPER_ID_CERT_PASSWORD}" \
  -f pkcs12 \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/productsign \
  >/dev/null
then
  ci_die "Could not import the Developer ID certificate. Check DEVELOPER_ID_CERT_PASSWORD, and export the certificate together with its private key."
fi
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN}" >/dev/null
security list-keychains -d user -s "${KEYCHAIN}"
security default-keychain -s "${KEYCHAIN}"

# find-identity only lists a Developer ID certificate when it can build a chain.
# The intermediates are not always in the user search list. Import them into
# the temporary signing keychain with add-certificates, which does not write
# trust settings. Skip the import when the identity is already valid.
developer_id_identity() {
  security find-identity -v -p codesigning "${KEYCHAIN}" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1
}

import_signing_intermediates() {
  local url dest name
  while IFS= read -r url; do
    [[ -z "${url}" ]] && continue
    dest=$(mktemp)
    name=$(basename "${url}")
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${url}"; then
      ci_log "WARNING: could not download ${url}"
      rm -f "${dest}"
      continue
    fi
    if security add-certificates -k "${KEYCHAIN}" "${dest}"; then
      ci_log "Imported ${name} into the temporary signing keychain without trust settings."
    else
      ci_log "WARNING: could not import ${name} into the temporary signing keychain."
    fi
    rm -f "${dest}"
  done <<'EOF'
https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
https://www.apple.com/certificateauthority/AppleWWDRCAG4.cer
https://www.apple.com/certificateauthority/AppleWWDRCAG5.cer
https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer
https://www.apple.com/certificateauthority/DeveloperIDCA.cer
https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
EOF
}

identity=$(developer_id_identity)
if [[ -z "${identity}" ]]; then
  ci_log "find-identity did not accept a Developer ID certificate yet. Importing WWDR and Developer ID intermediates into the temporary signing keychain."
  import_signing_intermediates
  identity=$(developer_id_identity)
fi
if [[ -z "${identity}" ]]; then
  security find-identity -v "${KEYCHAIN}" >&2 || true
  ci_die "No valid Developer ID Application identity in the temporary keychain. The .p12 must contain the certificate and its private key."
fi
ci_log "Signing identity: ${identity}"

# Archive unsigned. Signing inside-out afterwards is what covers nested
# frameworks, dylibs, and the Quick Look appex with one identity.
# \$(...) is an Xcode setting reference written into the xcconfig, not a shell expansion.
cat > "${xcconfig}" <<EOF
HEADER_SEARCH_PATHS = ${prefix}/include ${prefix}/include/OpenEXR ${prefix}/include/Imath
HEADER_SEARCH_PATHS[arch=*] = \$(HEADER_SEARCH_PATHS)
LIBRARY_SEARCH_PATHS = ${prefix}/lib
LIBRARY_SEARCH_PATHS[arch=*] = \$(LIBRARY_SEARCH_PATHS)
CODE_SIGN_STYLE = Manual
CODE_SIGNING_ALLOWED = NO
CODE_SIGNING_REQUIRED = NO
CODE_SIGN_IDENTITY =
CODE_SIGN_IDENTITY[sdk=macosx*] =
DEVELOPMENT_TEAM =
EOF
link_flags=$(ci_static_link_flags "${REPO_ROOT}/Generated/ThirdParty.generated.xcconfig")
printf 'OTHER_LDFLAGS = %s\n' "${link_flags}" >> "${xcconfig}"
ci_log "Linking with the generated static library list."
if [[ -n "${marketing}" ]]; then
  printf 'MARKETING_VERSION = %s\n' "${marketing}" >> "${xcconfig}"
fi

rm -rf "${archive}"
run_xcodebuild archive \
  -project Tristimulator.xcodeproj \
  -scheme Tristimulator \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${archive}" \
  -xcconfig "${xcconfig}"

app="${archive}/Products/Applications/Tristimulator.app"
appex="${app}/Contents/PlugIns/TristimulatorQuickLook.appex"
if [[ ! -d "${app}" ]]; then
  ci_log "Archive contents:"
  find "${archive}" -name '*.app' -o -name '*.appex' >&2 || true
  ci_die "Archive did not contain Products/Applications/Tristimulator.app."
fi
if [[ ! -d "${appex}" ]]; then
  ci_die "Quick Look extension was not embedded at Contents/PlugIns/TristimulatorQuickLook.appex."
fi

app_entitlements="${REPO_ROOT}/Tristimulator/Tristimulator.entitlements"
ql_entitlements="${REPO_ROOT}/TristimulatorQuickLook/TristimulatorQuickLook.entitlements"
if [[ ! -f "${app_entitlements}" || ! -f "${ql_entitlements}" ]]; then
  ci_die "Entitlements files are missing."
fi

sign_item() {
  local target="$1"
  local entitlements="${2:-}"
  if [[ -n "${entitlements}" ]]; then
    codesign --force --options runtime --timestamp \
      --keychain "${KEYCHAIN}" \
      --entitlements "${entitlements}" \
      --sign "${identity}" \
      "${target}"
  else
    codesign --force --options runtime --timestamp \
      --keychain "${KEYCHAIN}" \
      --sign "${identity}" \
      "${target}"
  fi
}

# Depth-first, so a dylib or framework inside the appex is signed before the
# appex, and the appex is signed before the outer app. --deep is not used.
while IFS= read -r item; do
  [[ -z "${item}" ]] && continue
  base=$(basename "${item}")
  case "${base}" in
    TristimulatorQuickLook.appex)
      ci_log "Signing Quick Look extension"
      sign_item "${item}" "${ql_entitlements}" || exit 1
      ;;
    *.appex)
      ci_die "Unexpected embedded appex: ${item}"
      ;;
    *)
      ci_log "Signing ${item#"${app}"/}"
      sign_item "${item}" || exit 1
      ;;
  esac
done <<EOF
$(find "${app}" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.so' -o -name '*.appex' -o -name '*.xpc' -o -name '*.bundle' \) -print)
EOF

ci_log "Signing Tristimulator.app"
sign_item "${app}" "${app_entitlements}"

codesign --verify --deep --strict --verbose=2 "${app}"
codesign --verify --strict --verbose=2 "${appex}"

# Capture the whole codesign -dv listing. Piping it to grep -q can SIGPIPE
# codesign, and with pipefail that looks like a missing runtime flag.
app_dv=$(codesign -dv "${app}" 2>&1 || true)
appex_dv=$(codesign -dv "${appex}" 2>&1 || true)
case "${app_dv}" in
  *flags=*runtime*) ;;
  *) ci_die "Tristimulator.app is missing the hardened runtime flag." ;;
esac
case "${appex_dv}" in
  *flags=*runtime*) ;;
  *) ci_die "TristimulatorQuickLook.appex is missing the hardened runtime flag." ;;
esac

app_team=$(printf '%s\n' "${app_dv}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
ql_team=$(printf '%s\n' "${appex_dv}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
if [[ "${app_team}" != "${APPLE_TEAM_ID}" || "${ql_team}" != "${APPLE_TEAM_ID}" ]]; then
  ci_die "Signed TeamIdentifier was app=${app_team:-<none>} extension=${ql_team:-<none>}. APPLE_TEAM_ID does not match the Developer ID certificate."
fi

binary="${app}/Contents/MacOS/Tristimulator"
lipo_info=$(lipo -info "${binary}")
ci_log "${lipo_info}"
case "${lipo_info}" in
  *"architecture: arm64"*) ;;
  *) ci_die "Expected a single-architecture arm64 Tristimulator binary." ;;
esac

rm -rf "${stage}"
mkdir -p "${stage}"
ditto "${app}" "${stage}/Tristimulator.app"
ln -s /Applications "${stage}/Applications"

attempt=1
while [[ "${attempt}" -le 3 ]]; do
  if hdiutil create -volname "Tristimulator" -srcfolder "${stage}" -ov -format UDZO "${dmg}"; then
    break
  fi
  if [[ "${attempt}" -eq 3 ]]; then
    ci_die "hdiutil could not create the DMG."
  fi
  ci_log "hdiutil failed (attempt ${attempt}). Retrying."
  sleep 5
  attempt=$((attempt + 1))
done

codesign --force --timestamp --keychain "${KEYCHAIN}" --sign "${identity}" "${dmg}"
codesign --verify --verbose=2 "${dmg}"

submit_json="${work}/notary.json"
set +e
xcrun notarytool submit "${dmg}" \
  --key "${P8_PATH}" \
  --key-id "${ASC_KEY_ID}" \
  --issuer "${ASC_ISSUER_ID}" \
  --wait \
  --timeout 45m \
  --output-format json > "${submit_json}"
submit_rc=$?
set -e

notary_fields=$(python3 - "${submit_json}" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception as exc:
    sys.stderr.write("notarytool did not return JSON (%s)\n" % exc)
    sys.stdout.write("\n\n")
    sys.exit(0)
status = data.get("status") or ""
ident = data.get("id") or ""
sys.stdout.write(status + "\n" + ident + "\n")
PY
)
notary_status=$(printf '%s\n' "${notary_fields}" | sed -n '1p')
notary_id=$(printf '%s\n' "${notary_fields}" | sed -n '2p')
ci_log "notarytool status: ${notary_status:-<none>} id: ${notary_id:-<none>} (exit ${submit_rc})"

if [[ "${notary_status}" != "Accepted" ]]; then
  if [[ -n "${notary_id}" ]]; then
    xcrun notarytool log "${notary_id}" \
      --key "${P8_PATH}" \
      --key-id "${ASC_KEY_ID}" \
      --issuer "${ASC_ISSUER_ID}" >&2 || true
  else
    cat "${submit_json}" >&2 || true
  fi
  ci_die "Notarization was not Accepted. The Apple log above is the reason. No GitHub Release was created."
fi

# GitHub-hosted runners sometimes drop stapler's HTTP/3 connection to CloudKit
# (UDP 443), which is stapler Error 68. Block that port so stapler uses TCP.
# The rules apply only to this job, and only on a GitHub Actions macOS runner.
# https://github.com/actions/runner-images/issues/14924
block_github_runner_udp_443() {
  if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_OS:-}" != "macOS" ]]; then
    ci_log "Not a GitHub Actions macOS runner. Leaving the packet filter unchanged."
    return 0
  fi
  ci_log "Blocking outbound UDP 443 so stapler uses HTTPS over TCP."
  if ! echo "block return out quick proto udp from any to any port 443" | sudo pfctl -f -; then
    ci_log "WARNING: pfctl -f failed. Continuing without a confirmed UDP 443 block."
  fi
  if ! sudo pfctl -E; then
    ci_log "WARNING: pfctl -E failed. Continuing."
  fi
}

# Admin trust settings are what add-trusted-cert writes. Log them before
# stapling so a later Error 65 shows whether custom trust is present.
# These dumps are noisy. They do not include private keys.
log_trust_settings() {
  ci_log "security dump-trust-settings (user domain):"
  security dump-trust-settings >&2 || true
  ci_log "security dump-trust-settings -d (admin domain):"
  # A clean runner has no admin trust settings and the command can exit non-zero
  # for that. The listing itself is the signal. Fall back to sudo when the
  # admin domain is not readable, without prompting.
  security dump-trust-settings -d >&2 || sudo -n security dump-trust-settings -d >&2 || true
}

# One verbose staple. Sets STAPLE_CLASS to ok, trust, or retry, and
# STAPLE_ELAPSED to the wall time in seconds.
# trust: the log says "Could not validate ticket" and does not say the ticket
# is missing. Stapler downloaded a ticket and rejected it locally. The v0.1.0
# runs did this in about 0.2s. Further attempts fail the same way.
# retry: "Record not found", "Could not find base64 encoded ticket", Error 68,
# or any other failure. The ticket may appear on a later attempt.
staple_once() {
  local log rc elapsed start now saw_record saw_validate
  log=$(mktemp)
  start=$(date +%s)
  set +e
  xcrun stapler staple -v "${dmg}" >"${log}" 2>&1
  rc=$?
  set -e
  now=$(date +%s)
  elapsed=$((now - start))
  STAPLE_ELAPSED=${elapsed}
  cat "${log}" >&2
  saw_record=false
  saw_validate=false
  if grep -q "Record not found" "${log}" || grep -q "Could not find base64 encoded ticket" "${log}"; then
    saw_record=true
  fi
  if grep -q "Could not validate ticket" "${log}"; then
    saw_validate=true
  fi
  if grep -q "Downloaded ticket has been stored" "${log}"; then
    ci_log "stapler downloaded a ticket (Downloaded ticket has been stored)."
  fi
  ci_log "stapler exit ${rc} after ${elapsed}s (record_not_found=${saw_record}, could_not_validate=${saw_validate})."
  rm -f "${log}"
  if [[ "${rc}" -eq 0 ]]; then
    STAPLE_CLASS=ok
    return 0
  fi
  if [[ "${saw_validate}" == "true" && "${saw_record}" == "false" ]]; then
    STAPLE_CLASS=trust
    return 0
  fi
  STAPLE_CLASS=retry
  return 0
}

# Gatekeeper can see an online notarization ticket before stapler attaches it.
gatekeeper_sees_ticket() {
  xcrun spctl --assess --type open --context context:primary-signature --ignore-cache --verbose=2 "${dmg}"
}

block_github_runner_udp_443
log_trust_settings

# The .app is not notarized on its own, so there is no ticket to staple onto
# it. Poll spctl, then staple the DMG. Six attempts with delays 15, 30, 60,
# 120, and 240 seconds is about 7.5 minutes of sleep, the same shape as
# Node's tools/osx-notarize.sh. A trust-evaluation failure does not use that
# budget: the first staple is verbose, and "Could not validate ticket"
# without a missing-ticket line stops the loop.
stapled=false
STAPLE_CLASS=retry
STAPLE_ELAPSED=0
delay=15
attempt=1
staple_max=6
ci_log "Staple budget: ${staple_max} attempts, backoff from ${delay}s (about 8 minutes). A local trust rejection stops immediately."
while [[ "${attempt}" -le "${staple_max}" ]]; do
  ci_log "Notarization ticket check ${attempt}/${staple_max}."
  if gatekeeper_sees_ticket; then
    ci_log "spctl --assess accepted the DMG. The ticket is online."
    ticket_online=true
  else
    ci_log "spctl --assess has not accepted the DMG yet."
    ticket_online=false
  fi

  # Always staple on the first attempt so a trust rejection is in the log
  # before any sleep. After that, staple once Gatekeeper can see the ticket.
  # The last attempt staples even if spctl never accepts the DMG here.
  if [[ "${attempt}" -eq 1 || "${ticket_online}" == "true" || "${attempt}" -eq "${staple_max}" ]]; then
    staple_once
    case "${STAPLE_CLASS}" in
      ok)
        stapled=true
        break
        ;;
      trust)
        ci_log "stapler rejected the ticket locally after ${STAPLE_ELAPSED}s (Could not validate ticket). This is trust evaluation, not a missing ticket. Not retrying."
        break
        ;;
      retry)
        ci_log "stapler did not attach the ticket."
        ;;
    esac
  fi

  if [[ "${attempt}" -eq "${staple_max}" ]]; then
    break
  fi
  ci_log "Retrying in ${delay}s."
  sleep "${delay}"
  delay=$((delay * 2))
  attempt=$((attempt + 1))
done

if [[ "${stapled}" == "true" ]]; then
  if xcrun stapler validate "${dmg}"; then
    ci_log "stapler validate passed."
  else
    ci_log "stapler validate failed after staple reported success. Treating the DMG as unstapled."
    stapled=false
  fi
fi

if [[ "${stapled}" == "true" ]]; then
  if gatekeeper_sees_ticket; then
    ci_log "spctl accepted the DMG on this runner."
  else
    ci_log "spctl did not accept the DMG on this runner. stapler validate passed. Confirm Gatekeeper on a Mac before publishing the draft."
  fi
else
  ci_log "Stapling failed. The signed, notarized DMG will still be uploaded and attached to a draft release marked unstapled."
  printf '::warning::Stapling failed. The notarized DMG will be attached to a draft release marked unstapled. Do not publish it.\n' >&2
fi

checksum=$(shasum -a 256 "${dmg}" | awk '{ print $1 }')
ci_log "DMG ${dmg}"
ci_log "SHA-256 ${checksum}"
ci_log "stapled=${stapled}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  if [[ "${stapled}" == "true" ]]; then
    cat >> "${GITHUB_STEP_SUMMARY}" <<EOF
### Stapled DMG

File: ${dmg##*/}

SHA-256: ${checksum}
EOF
  else
    cat >> "${GITHUB_STEP_SUMMARY}" <<EOF
### Unstapled DMG: do not publish

Notarization was Accepted, but stapler did not attach the ticket. This DMG is still uploaded and attached to a draft release marked unstapled. The workflow fails after that upload.

File: ${dmg##*/}

SHA-256: ${checksum}
EOF
  fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'tag=%s\n' "${tag}"
    printf 'dmg=%s\n' "${dmg}"
    printf 'checksum=%s\n' "${checksum}"
    printf 'stapled=%s\n' "${stapled}"
  } >> "${GITHUB_OUTPUT}"
fi
