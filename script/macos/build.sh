#!/bin/bash
# Builds .cache/release/macos/Bookalog Catalog.app and its disk image, signed
# for distribution.
#
#   bash script/macos/build.sh
#
# Signing is controlled by BOOKALOG_SIGNING_IDENTITY (see common.sh). With a
# Developer ID identity every framework is signed with the Hardened Runtime and
# a secure timestamp, the app is signed with app/macos/Runner/Release.entitlements,
# which is what notarization requires, and the disk image is signed with the
# same identity. Without one the app falls back to an ad-hoc signature without
# the Hardened Runtime: runnable on this Mac, and on others only after Open
# Anyway. The disk image is then left unsigned.
#
# Secure storage uses the data protection keychain, which needs the
# keychain-access-groups entitlement and therefore a Developer ID provisioning
# profile for BUNDLE_ID. Set BOOKALOG_PROVISIONING_PROFILE to its
# .provisionprofile path; it is embedded and its application identifier added
# to the signed entitlements. With BOOKALOG_REQUIRE_NOTARIZATION=1 a missing
# profile is an error.
#
# SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY and OFFLINE_LEASE_PUBLIC_KEY are
# compiled in when set (see check_configuration in script/release-common.sh).
set -euo pipefail

# shellcheck source=script/macos/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$(repo_root)"

(( $# == 0 )) || die "build.sh takes no arguments. Choose the signing identity with BOOKALOG_SIGNING_IDENTITY."
[[ "$(uname -s)" == Darwin ]] || die "the macOS build requires a macOS host with Xcode."
command -v "${FLUTTER_BIN:-flutter}" > /dev/null || die "Flutter is not installed. Set FLUTTER_BIN if it is not on PATH."

VERSION="$(app_version)"
IDENTITY="$(resolve_signing_identity)"
DMG="$(dmg_path)"
WORK="$(mktemp -d -t bookalog-macos-build)"
trap 'rm -rf "${WORK}"' EXIT

plutil -lint "${ENTITLEMENTS}" > /dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "${ENTITLEMENTS}")" == true ]] \
    || die "native file exchange requires the user-selected read/write entitlement."
check_configuration

PROFILE="${BOOKALOG_PROVISIONING_PROFILE:-}"
if ! is_adhoc "${IDENTITY}"; then
    TEAM_ID="$(team_id_from_identity "${IDENTITY}")"
    [[ "${TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]] || die "couldn't tell the Team ID of ${IDENTITY}. Set BOOKALOG_TEAM_ID."
    if [[ -z "${PROFILE}" ]]; then
        if [[ "${BOOKALOG_REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
            die "BOOKALOG_PROVISIONING_PROFILE is required for a release: without it the signed app cannot use the data protection keychain that stores sign-in sessions."
        fi
        warn "no BOOKALOG_PROVISIONING_PROFILE, so the signed app cannot use the data protection keychain and sign-in will not persist."
    else
        [[ -f "${PROFILE}" ]] || die "${PROFILE} not found."
        security cms -D -i "${PROFILE}" > "${WORK}/profile.plist" 2>/dev/null \
            || die "${PROFILE} is not a signed provisioning profile."
        PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "${WORK}/profile.plist" 2>/dev/null || true)"
        [[ "${PROFILE_APP_ID}" == "${TEAM_ID}.${BUNDLE_ID}" ]] \
            || die "${PROFILE} is for ${PROFILE_APP_ID:-no application}, not ${TEAM_ID}.${BUNDLE_ID}."
        PROFILE_EXPIRES="$(plutil -extract ExpirationDate raw "${WORK}/profile.plist")"
        [[ "${PROFILE_EXPIRES}" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] \
            || die "${PROFILE} expired on ${PROFILE_EXPIRES}."
        /usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' "${WORK}/profile.plist" > /dev/null 2>&1 \
            || die "${PROFILE} does not grant keychain access groups."
    fi
fi

log "Building ${APP_NAME} ${VERSION}"
rm -rf "$(dirname "${APP}")" "${DMG}" "${DMG}.sha256"
mkdir -p "$(dirname "${APP}")"
# Signing happens below, once the app is copied out of the build tree.
(export CODE_SIGNING_ALLOWED=NO; flutter_release_build macos)
[[ -x "${BUILT_APP}/Contents/MacOS/${APP_NAME}" ]] || die "Flutter did not produce ${BUILT_APP}"
ditto "${BUILT_APP}" "${APP}"

PLIST="${APP}/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")" == "${VERSION}" ]] \
    || die "${APP} does not carry version ${VERSION}."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}")" == "${BUNDLE_ID}" ]] \
    || die "${APP} is not ${BUNDLE_ID}."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "${PLIST}" 2>/dev/null)" == "${CALLBACK_SCHEME}" ]] \
    || die "${APP} does not register the ${CALLBACK_SCHEME} sign-in callback."

# Nested code is signed before what contains it; -depth lists it in that order.
nested_code() {
    find "${APP}/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null
}

if is_adhoc "${IDENTITY}"; then
    warn "signing ad-hoc because $(adhoc_reason).
         The app will run on this Mac, but other Macs open it only after Open
         Anyway, and it cannot be notarized. Set BOOKALOG_SIGNING_IDENTITY to a
         Developer ID identity to sign for distribution."
    while IFS= read -r -d '' code; do
        codesign --force --sign - "${code}"
    done < <(nested_code)
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP}"
else
    log "Signing as ${IDENTITY}"
    cp "${ENTITLEMENTS}" "${WORK}/entitlements.plist"
    if [[ -n "${PROFILE}" ]]; then
        cp "${PROFILE}" "${APP}/Contents/embedded.provisionprofile"
        /usr/libexec/PlistBuddy \
            -c "Add :com.apple.application-identifier string ${TEAM_ID}.${BUNDLE_ID}" \
            -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" \
            -c "Add :keychain-access-groups array" \
            -c "Add :keychain-access-groups:0 string ${TEAM_ID}.${BUNDLE_ID}" \
            "${WORK}/entitlements.plist"
    fi
    while IFS= read -r -d '' code; do
        codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${code}"
    done < <(nested_code)
    codesign --force --options runtime --timestamp --sign "${IDENTITY}" \
        --entitlements "${WORK}/entitlements.plist" "${APP}"
fi

log "Verifying the app signature"
codesign --verify --strict --deep --verbose=2 "${APP}"
if ! is_adhoc "${IDENTITY}"; then
    SIGNED_TEAM="$(codesign --display --verbose=2 "${APP}" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
    [[ "${SIGNED_TEAM}" == "${TEAM_ID}" ]] || die "${APP} is signed by team ${SIGNED_TEAM:-none}, not ${TEAM_ID}."
    codesign --display --verbose=2 "${APP}" 2>&1 | grep -q 'flags=.*runtime' \
        || die "${APP} is not signed with the Hardened Runtime."
    # Before notarization this reports "rejected ... Unnotarized Developer ID",
    # which is expected; notarize.sh checks the app again afterwards.
    spctl --assess --type execute --verbose=2 "${APP}" || true
fi

ruby script/package-macos.rb "${APP}" "${DMG}"

if is_adhoc "${IDENTITY}"; then
    warn "leaving ${DMG} unsigned (not distributable)."
else
    # Signing the image is what lets stapler attach the notarization ticket to
    # the .dmg itself rather than only to the app inside it.
    log "Signing ${DMG} as ${IDENTITY}"
    codesign --force --sign "${IDENTITY}" --timestamp "${DMG}"
    codesign --verify --verbose=2 "${DMG}"
fi

log "Done: ${DMG} ($(du -h "${DMG}" | cut -f1))"
