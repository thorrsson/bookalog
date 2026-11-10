#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby script/fixtures.rb
npm --prefix spikes/tauri run build
cargo test --manifest-path spikes/tauri/src-tauri/Cargo.toml
