#!/bin/bash
# Shared configuration and helpers for the macOS release scripts.
# Sourced, never executed directly.
# shellcheck disable=SC2034  # the constants are used by the sourcing scripts

MACOS_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/release-common.sh
source "${MACOS_SCRIPTS}/../release-common.sh"

APP_NAME="Bookalog Catalog"
BUNDLE_ID="com.bookalog.bookalogCatalog"
CALLBACK_SCHEME="com.bookalog.catalog"
DIST=".cache/release"
BUILT_APP="app/build/macos/Build/Products/Release/${APP_NAME}.app"
APP="${DIST}/macos/${APP_NAME}.app"
ENTITLEMENTS="app/macos/Runner/Release.entitlements"

# Everything runs from the repository root so the paths above are stable.
repo_root() {
    (cd "${MACOS_SCRIPTS}/../.." && pwd)
}

artifact_base() {
    printf '%s/Bookalog-Catalog-%s-macos' "${DIST}" "$(app_version)"
}

dmg_path() { printf '%s.dmg' "$(artifact_base)"; }
zip_path() { printf '%s.zip' "$(artifact_base)"; }

# Resolve the codesigning identity once, so the app and the disk image are
# signed by the same thing.
#
#   BOOKALOG_SIGNING_IDENTITY  an explicit identity or SHA-1 hash; "-" forces ad-hoc
#   (unset)                    the first Developer ID Application identity in the
#                              keychain, or ad-hoc if there is none
#
# Ad-hoc signatures are fine locally but cannot be notarized: Gatekeeper on
# another Mac will refuse the result, so the release path checks for this.
resolve_signing_identity() {
    if [[ -n "${BOOKALOG_SIGNING_IDENTITY:-}" ]]; then
        printf '%s' "${BOOKALOG_SIGNING_IDENTITY}"
        return
    fi
    local found
    # awk reads to the end rather than exiting at the first match, which would
    # leave security writing to a closed pipe and fail the pipeline.
    found="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ && !found { print $2; found = 1 }')"
    if [[ -n "${found}" ]]; then
        printf '%s' "${found}"
        return
    fi
    printf '%s' '-'
}

is_adhoc() { [[ "${1}" == "-" ]]; }

# Why resolve_signing_identity settled on ad-hoc, for the warnings that say so.
adhoc_reason() {
    if [[ "${BOOKALOG_SIGNING_IDENTITY:-}" == "-" ]]; then
        printf '%s' 'BOOKALOG_SIGNING_IDENTITY is "-"'
    else
        printf '%s' 'there is no Developer ID Application identity in the keychain'
    fi
}

# The Team ID lives in parentheses at the end of a Developer ID identity name.
team_id_from_identity() {
    local identity="${1}"
    if [[ -n "${BOOKALOG_TEAM_ID:-}" ]]; then
        printf '%s' "${BOOKALOG_TEAM_ID}"
        return
    fi
    if [[ "${identity}" =~ \(([A-Z0-9]{10})\)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Credentials for notarize.sh, in the order it tries them. See that script.
has_notary_credentials() {
    if [[ -n "${BOOKALOG_NOTARY_PROFILE:-}" ]]; then
        return 0
    fi
    if [[ -n "${NOTARY_API_KEY_P8:-}" && -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" ]]; then
        return 0
    fi
    [[ -n "${BOOKALOG_APPLE_ID:-}" && -n "${BOOKALOG_APPLE_PASSWORD:-}" ]]
}
