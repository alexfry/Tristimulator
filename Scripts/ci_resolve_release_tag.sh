#!/bin/bash
# Validate RELEASE_TAG and record it for later steps.
# Accepts v1.2.3 and v1.2.3-rc1. Rejects anything that could break out of a shell word.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ci_common.sh
source "${SCRIPT_DIR}/ci_common.sh"

tag="${RELEASE_TAG:-}"
if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z]+)*$ ]]; then
  ci_die "Release tag must look like v1.2.3 or v1.2.3-rc1."
fi

marketing=""
if [[ "${tag}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  marketing="${BASH_REMATCH[1]}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'tag=%s\n' "${tag}"
    printf 'marketing_version=%s\n' "${marketing}"
  } >> "${GITHUB_OUTPUT}"
else
  printf '%s\n' "${tag}"
fi

ci_log "Release tag ${tag}"
