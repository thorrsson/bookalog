#!/bin/bash
# One command from a clean checkout to a notarized, distributable disk image.
#
#   bash script/macos/release.sh
#
# Runs the app checks (script/test-app.sh), builds and signs the app and its
# disk image, notarizes the image, staples the app, archives it as a ZIP, and
# writes SHA-256 checksums beside both. Notarization is skipped, with a loud
# warning rather than an error, when there is no Developer ID identity or no
# credentials, so the same command still produces a local build. Set
# BOOKALOG_REQUIRE_NOTARIZATION=1 (the release workflow does) to make that a
# failure instead, and BOOKALOG_SKIP_TESTS=1 to skip the checks.
set -euo pipefail

# shellcheck source=script/macos/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$(repo_root)"

VERSION="$(app_version)"
IDENTITY="$(resolve_signing_identity)"
DMG="$(dmg_path)"
ZIP="$(zip_path)"

log "Releasing ${APP_NAME} ${VERSION}"

# Decided before building, so a release that cannot be notarized fails in
# seconds rather than after the build.
SKIP_REASON=""
if is_adhoc "${IDENTITY}"; then
    SKIP_REASON="the build is signed ad-hoc because $(adhoc_reason)"
elif ! has_notary_credentials; then
    SKIP_REASON="no notarization credentials are configured"
fi
if [[ -n "${SKIP_REASON}" && "${BOOKALOG_REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
    die "notarization required but ${SKIP_REASON}."
fi

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "the working tree is dirty; the build will not match any commit."
fi

if [[ "${BOOKALOG_SKIP_TESTS:-0}" != "1" ]]; then
    log "Running the app checks"
    bash script/test-app.sh
fi

bash "${MACOS_SCRIPTS}/build.sh"

if [[ -n "${SKIP_REASON}" ]]; then
    warn "skipping notarization: ${SKIP_REASON}. ${DMG} is a local build:
         opening it on another Mac will show 'Apple could not verify' or refuse
         outright."
else
    bash "${MACOS_SCRIPTS}/notarize.sh" "${DMG}"
    # The image's notarization also covers the identical signed app beside it.
    # Staple that app before archiving it, for offline Gatekeeper checks.
    xcrun stapler staple "${APP}"
    xcrun stapler validate "${APP}"
    spctl --assess --type execute --verbose=2 "${APP}"
fi

rm -f "${ZIP}" "${ZIP}.sha256"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

# A checksum published beside each download lets anyone confirm they got the
# same bytes, which is the one integrity check that does not depend on Apple.
# It is written from inside the output directory so the recorded name is the
# bare file, which is what `shasum -c` in a downloads folder has to find.
# Stapling rewrites the image, so this comes last.
(
    cd "${DIST}"
    for file in "$(basename "${DMG}")" "$(basename "${ZIP}")"; do
        shasum -a 256 "${file}" | tee "${file}.sha256"
    done
)

log "Release artifacts in ${DIST}/"
ls -lh "${DMG}" "${DMG}.sha256" "${ZIP}" "${ZIP}.sha256"
