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
  for attempt in 1 2 3; do
    if curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 60 --max-filesize 10485760 \
      --write-out 'ONIX schema response: HTTP %{http_code}, %{content_type}, %{size_download} bytes\n' \
      'https://www.editeur.org/files/ONIX%203/ONIX_BookProduct_3.0_XSDs+codes_Issue_75.zip' \
      -o "$download"; then
      actual="$(openssl dgst -sha256 "$download")"
      actual="${actual##* }"
      if [ "$actual" = "$expected" ]; then
        mv "$download" "$archive"
        break
      fi
      echo "ONIX schema download $attempt/3 has an unrecognized checksum: $actual" >&2
    else
      echo "ONIX schema download $attempt/3 failed." >&2
    fi
    if [ "$attempt" -lt 3 ]; then sleep "$((attempt * 2))"; fi
  done
  if [ ! -f "$archive" ]; then
    echo "Could not obtain the pinned ONIX schema after 3 attempts. Review the upstream response before changing the pin." >&2
    exit 1
  fi
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
