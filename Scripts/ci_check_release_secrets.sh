#!/bin/bash
# Exit before any compile if the release job is missing a signing secret.
# Prints names only, never values. The build/test workflow does not call this.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ci_common.sh
source "${SCRIPT_DIR}/ci_common.sh"

missing=""
require() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    missing="${missing} ${name}"
  fi
}

require DEVELOPER_ID_CERT_P12_BASE64 "${DEVELOPER_ID_CERT_P12_BASE64:-}"
require DEVELOPER_ID_CERT_PASSWORD "${DEVELOPER_ID_CERT_PASSWORD:-}"
require APPLE_TEAM_ID "${APPLE_TEAM_ID:-}"
require ASC_KEY_ID "${ASC_KEY_ID:-}"
require ASC_ISSUER_ID "${ASC_ISSUER_ID:-}"
require ASC_KEY_P8_BASE64 "${ASC_KEY_P8_BASE64:-}"
require KEYCHAIN_PASSWORD "${KEYCHAIN_PASSWORD:-}"

if [[ -n "${missing}" ]]; then
  ci_die "Release secrets are not set:${missing}. Add them as repository Actions secrets. The steps are in docs/CI.md. The build/test workflow does not use these."
fi

if [[ ! "${APPLE_TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
  ci_die "APPLE_TEAM_ID must be the 10-character Team ID from the Apple Developer membership page."
fi

if [[ ! "${ASC_KEY_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
  ci_die "ASC_KEY_ID must be the 10-character App Store Connect API key id."
fi

if [[ ! "${ASC_ISSUER_ID}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  ci_die "ASC_ISSUER_ID must be the issuer UUID at the top of the App Store Connect API page."
fi

if [[ "${#KEYCHAIN_PASSWORD}" -lt 8 ]]; then
  ci_die "KEYCHAIN_PASSWORD must be at least 8 characters. It is a password you invent for the temporary CI keychain, not an Apple ID password."
fi

ci_log "Release secrets are present."
