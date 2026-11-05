#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node --test supabase/functions/offline-lease/handler.test.mjs
