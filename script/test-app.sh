#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../app"
lease_vector="$(mktemp "${TMPDIR:-/tmp}/bookalog-lease.XXXXXX")"
export BOOKALOG_LEASE_TEST_VECTOR="$lease_vector"
export BOOKALOG_EXCHANGE_TEST_EXPORT="$lease_vector.xlsx"
export BOOKALOG_ONIX_TEST_EXPORT="$lease_vector.onix"
trap 'rm -f "$lease_vector" "$BOOKALOG_EXCHANGE_TEST_EXPORT" "$BOOKALOG_EXCHANGE_TEST_EXPORT.json" "$BOOKALOG_ONIX_TEST_EXPORT" "$BOOKALOG_ONIX_TEST_EXPORT.json" "$BOOKALOG_ONIX_TEST_EXPORT.sample.xml" "$BOOKALOG_ONIX_TEST_EXPORT.external.xml"' EXIT
bash ../script/test-offline-lease.sh
"${FLUTTER_BIN:-flutter}" analyze
"${FLUTTER_BIN:-flutter}" test "$@"
if [ -f "$BOOKALOG_EXCHANGE_TEST_EXPORT" ]; then
  node ../script/verify-app-exchange.mjs "$BOOKALOG_EXCHANGE_TEST_EXPORT"
fi
if [ -f "$BOOKALOG_ONIX_TEST_EXPORT" ]; then
  node ../script/verify-app-onix.mjs "$BOOKALOG_ONIX_TEST_EXPORT"
  bash ../script/validate-onix.sh "$BOOKALOG_ONIX_TEST_EXPORT"
  bash ../script/validate-onix.sh "$BOOKALOG_ONIX_TEST_EXPORT.sample.xml"
  bash ../script/validate-onix.sh "$BOOKALOG_ONIX_TEST_EXPORT.external.xml"
fi
