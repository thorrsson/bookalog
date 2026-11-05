#!/bin/bash
# Starts the built app and checks it is still running after a few seconds.
#
#   bash script/macos/launch-check.sh [path/to/Bookalog Catalog.app]
#
# The signed release runs under the Hardened Runtime and its provisioning
# profile, which the unsigned CI build does not, so a bad signature,
# entitlement or profile shows up here as a crash at launch rather than on a
# staff member's Mac. It only proves the app starts; it does not sign in.
set -euo pipefail

# shellcheck source=script/macos/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$(repo_root)"

(( $# <= 1 )) || die "usage: launch-check.sh [app]"
TARGET="${1:-${APP}}"
EXECUTABLE="${TARGET}/Contents/MacOS/${APP_NAME}"
[[ -x "${EXECUTABLE}" ]] || die "${EXECUTABLE} not found. Run bash script/macos/build.sh first."
SECONDS_ALIVE="${BOOKALOG_LAUNCH_SECONDS:-10}"

LOG="$(mktemp -t bookalog-launch)"
"${EXECUTABLE}" > "${LOG}" 2>&1 &
PID=$!
cleanup() {
    kill "${PID}" 2>/dev/null || true
    wait "${PID}" 2>/dev/null || true
    rm -f "${LOG}"
}
trap cleanup EXIT

sleep "${SECONDS_ALIVE}"
if ! kill -0 "${PID}" 2>/dev/null; then
    status=0
    wait "${PID}" || status=$?
    cat "${LOG}" >&2
    die "${TARGET} exited with status ${status} within ${SECONDS_ALIVE} seconds of launch."
fi
log "${TARGET} is running after ${SECONDS_ALIVE} seconds"
