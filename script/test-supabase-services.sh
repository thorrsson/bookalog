#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec ruby script/test-supabase-services.rb
