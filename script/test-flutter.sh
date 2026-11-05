#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby script/fixtures.rb
cd spikes/flutter
"${FLUTTER_BIN:-flutter}" analyze
"${FLUTTER_BIN:-flutter}" test
