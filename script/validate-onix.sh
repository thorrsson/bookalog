#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: bash script/validate-onix.sh /absolute/path/to/export.xml" >&2
  exit 1
fi
for tool in curl unzip openssl xmllint; do
  if ! command -v "$tool" >/dev/null; then
    echo "ONIX schema validation requires $tool." >&2
    exit 1
  fi
done

# EDItEUR 3.0.8 classic XSD, codelists issue 75. Validation stays entirely local.
archive=".cache/onix/schema.zip"
directory=".cache/onix/ONIX_BookProduct_3.0_XSDs+codes_Issue_75"
expected="99d68d13d964de6e2827c5b330ca2a9d20b3fc185db587b24fc1e0441242e774"
mkdir -p .cache/onix
if [ ! -f "$archive" ]; then
  download="$archive.part.$$"
  trap 'rm -f "$download"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    'https://www.editeur.org/files/ONIX%203/ONIX_BookProduct_3.0_XSDs+codes_Issue_75.zip' \
    -o "$download"
  actual="$(openssl dgst -sha256 "$download")"
  actual="${actual##* }"
  if [ "$actual" != "$expected" ]; then
    echo "ONIX schema archive checksum changed; review the upstream release before updating the pin." >&2
    exit 1
  fi
  mv "$download" "$archive"
fi
actual="$(openssl dgst -sha256 "$archive")"
actual="${actual##* }"
if [ "$actual" != "$expected" ]; then
  echo "Cached ONIX schema archive failed its pinned checksum." >&2
  exit 1
fi
unzip -o -q "$archive" \
  'ONIX_BookProduct_3.0_XSDs+codes_Issue_75/ONIX_BookProduct_3.0_reference.xsd' \
  'ONIX_BookProduct_3.0_XSDs+codes_Issue_75/ONIX_BookProduct_CodeLists.xsd' \
  'ONIX_BookProduct_3.0_XSDs+codes_Issue_75/ONIX_XHTML_Subset.xsd' \
  -d .cache/onix
xmllint --nonet --noout --schema "$directory/ONIX_BookProduct_3.0_reference.xsd" "$1"
