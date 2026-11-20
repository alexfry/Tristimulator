#!/bin/bash
# Attach the notarized DMG to a draft GitHub Release. Creates the release when
# this tag does not have one yet. A stapled re-run replaces the asset and leaves
# an already-published release published. An unstapled DMG is attached to a
# draft whose title and notes say not to publish it. If that tag was already
# published, it is moved back to a draft before the asset is replaced.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ci_common.sh
source "${SCRIPT_DIR}/ci_common.sh"

tag="${RELEASE_TAG:-}"
dmg="${RELEASE_DMG:-}"
checksum="${RELEASE_SHA256:-}"
stapled="${RELEASE_STAPLED:-}"

if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z]+)*$ ]]; then
  ci_die "RELEASE_TAG must look like v1.2.3 or v1.2.3-rc1."
fi
if [[ ! -f "${dmg}" ]]; then
  ci_die "DMG does not exist."
fi
if [[ ! "${checksum}" =~ ^[0-9a-f]{64}$ ]]; then
  ci_die "SHA-256 from the package step is missing."
fi
if [[ "${stapled}" != "true" && "${stapled}" != "false" ]]; then
  ci_die "RELEASE_STAPLED must be true or false."
fi
if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_SHA:-}" ]]; then
  ci_die "GITHUB_REPOSITORY and GITHUB_SHA must be set."
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  ci_die "GH_TOKEN is not set. The release workflow should pass github.token."
fi

if [[ "${stapled}" == "true" ]]; then
  title="Tristimulator ${tag}"
else
  title="Tristimulator ${tag} (UNSTAPLED - do not publish)"
fi

notes=$(mktemp)
if [[ "${stapled}" == "true" ]]; then
  cat > "${notes}" <<EOF
Draft Tristimulator ${tag}.

The DMG is signed with Developer ID Application, the hardened runtime, a secure timestamp, and the app entitlements. Nested frameworks, dylibs, and TristimulatorQuickLook.appex are signed the same way. The DMG was notarized with notarytool and stapled.

Install the DMG on a Mac and confirm Gatekeeper before publishing this draft.

SHA-256: ${checksum}
Commit: ${GITHUB_SHA}
EOF
else
  cat > "${notes}" <<EOF
Draft Tristimulator ${tag}.

WARNING: THIS DMG IS NOT STAPLED. Do not publish this draft.

notarytool Accepted the DMG, but stapler did not attach the notarization ticket. Gatekeeper on an online Mac can still ask Apple about the ticket. Gatekeeper on an offline Mac will not. The workflow artifact is this same file.

The DMG is signed with Developer ID Application, the hardened runtime, a secure timestamp, and the app entitlements. Nested frameworks, dylibs, and TristimulatorQuickLook.appex are signed the same way.

Install the DMG on a Mac and confirm Gatekeeper before publishing anything.

SHA-256: ${checksum}
Commit: ${GITHUB_SHA}
EOF
fi

if gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
  edit_args=(
    release edit "${tag}"
    --repo "${GITHUB_REPOSITORY}"
    --title "${title}"
    --notes-file "${notes}"
  )
  if [[ "${stapled}" == "false" ]]; then
    # --draft marks the release as a draft. Do not pass --draft=false: that publishes.
    edit_args+=(--draft)
    ci_log "Release ${tag} already exists. The DMG is not stapled, so the release is a draft marked do-not-publish."
  else
    ci_log "Release ${tag} already exists. Uploading a replacement asset."
  fi
  gh "${edit_args[@]}"
  gh release upload "${tag}" "${dmg}" --repo "${GITHUB_REPOSITORY}" --clobber
else
  create_args=(
    release create "${tag}" "${dmg}"
    --repo "${GITHUB_REPOSITORY}"
    --draft
    --title "${title}"
    --notes-file "${notes}"
  )
  # A pushed tag already points at this commit. workflow_dispatch may not
  # have a tag yet, so create that tag on the commit that was built.
  if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
    create_args+=(--target "${GITHUB_SHA}")
  fi
  gh "${create_args[@]}"
fi

rm -f "${notes}"
if [[ "${stapled}" == "true" ]]; then
  ci_log "Draft release asset attached for ${tag}."
else
  ci_log "Unstapled DMG attached to draft release ${tag}. Do not publish it."
fi
