#!/bin/bash
# Builds the Windows release: a portable ZIP and, when a code-signing
# certificate is configured, a signed MSIX installer. Runs in Git Bash.
#
#   bash script/windows/release.sh
#
#   WINDOWS_CERTIFICATE           the PFX, as a file path or base64 content
#   WINDOWS_CERTIFICATE_PASSWORD  its password
#
# Without a certificate the MSIX is skipped with a warning: Windows will not
# install an unsigned MSIX, and the ZIP alone does not register the sign-in
# callback, so that release can only be browsed after a manual sign-in setup.
# BOOKALOG_SKIP_TESTS=1 skips the app checks; BOOKALOG_REQUIRE_CONFIGURATION=1
# refuses a build without the hosted configuration.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=script/release-common.sh
source script/release-common.sh

case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *) die "the Windows release requires Git Bash on Windows with Visual Studio C++ tools." ;;
esac
command -v "${FLUTTER_BIN:-flutter}" > /dev/null || die "Flutter is not installed. Set FLUTTER_BIN if it is not on PATH."
command -v 7z > /dev/null || die "Windows packaging requires 7-Zip (7z) on PATH."

DIST=".cache/release"
VERSION="$(app_version)"
MSIX_VERSION="$(ruby script/app-version.rb msix)"
BASE="Bookalog-Catalog-${VERSION}-windows"
RELEASE_DIR="app/build/windows/x64/runner/Release"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log "Releasing Bookalog Catalog ${VERSION} for Windows"
check_configuration

CERTIFICATE=""
if [[ -n "${WINDOWS_CERTIFICATE:-}" ]]; then
    [[ -n "${WINDOWS_CERTIFICATE_PASSWORD:-}" ]] || die "WINDOWS_CERTIFICATE is set but WINDOWS_CERTIFICATE_PASSWORD is not."
    if [[ -f "${WINDOWS_CERTIFICATE}" ]]; then
        CERTIFICATE="$(cd "$(dirname "${WINDOWS_CERTIFICATE}")" && pwd)/$(basename "${WINDOWS_CERTIFICATE}")"
    else
        CERTIFICATE="${WORK}/certificate.pfx"
        printf '%s' "${WINDOWS_CERTIFICATE}" | base64 --decode > "${CERTIFICATE}" \
            || die "WINDOWS_CERTIFICATE is neither a file nor base64."
    fi
    # Checked before building so a bad certificate fails in seconds.
    PUBLISHER="$(powershell.exe -NoProfile -NonInteractive -File script/windows/certificate-subject.ps1 "$(cygpath -w "${CERTIFICATE}")")"
    [[ -n "${PUBLISHER}" ]] || die "couldn't read the certificate subject."
    log "Signing as ${PUBLISHER}"
else
    warn "WINDOWS_CERTIFICATE is not set, so no MSIX installer is built. The portable ZIP
         does not register the sign-in callback and Windows SmartScreen will warn
         before it runs."
fi

if [[ "${BOOKALOG_SKIP_TESTS:-0}" != "1" ]]; then
    log "Running the app checks"
    bash script/test-app.sh
fi

flutter_release_build windows
[[ -f "${RELEASE_DIR}/bookalog_catalog.exe" ]] || die "Flutter did not produce ${RELEASE_DIR}/bookalog_catalog.exe"

mkdir -p "${DIST}"
rm -f "${DIST}/${BASE}".*
archive="${PWD}/${DIST}/${BASE}.zip"
(cd "${RELEASE_DIR}" && 7z a -tzip "${archive}" . > /dev/null)
[[ -s "${archive}" ]] || die "7-Zip did not produce ${archive}"
artifacts=("${BASE}.zip")

if [[ -n "${CERTIFICATE}" ]]; then
    # The publisher is passed explicitly: msix keeps the development publisher
    # from app/pubspec.yaml otherwise, and Windows rejects a package whose
    # publisher differs from its signer.
    (cd app && "${DART_BIN:-dart}" run msix:create \
        --build-windows false \
        --version "${MSIX_VERSION}" \
        --publisher "${PUBLISHER}" \
        --certificate-path "$(cygpath -w "${CERTIFICATE}")" \
        --certificate-password "${WINDOWS_CERTIFICATE_PASSWORD}" \
        --sign-msix true \
        --install-certificate false \
        --output-path "../${DIST}" \
        --output-name "${BASE}")
    powershell.exe -NoProfile -NonInteractive -File script/test-windows-package.ps1 \
        -Package "$(cygpath -w "${DIST}/${BASE}.msix")" -Publisher "${PUBLISHER}" -Signed
    artifacts+=("${BASE}.msix")
fi

# Written from inside the output directory so `shasum -c` finds the bare name.
(
    cd "${DIST}"
    for file in "${artifacts[@]}"; do
        sha256sum "${file}" | tee "${file}.sha256"
    done
)

log "Release artifacts in ${DIST}/"
ls -l "${DIST}/${BASE}".*
