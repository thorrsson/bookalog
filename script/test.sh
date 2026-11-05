#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby script/fixtures.rb
if ! docker info >/dev/null 2>&1; then
  echo "PostgreSQL integration tests require a running Docker engine." >&2
  exit 1
fi
password="$(openssl rand -hex 24)"
container="$(docker run --rm -d -e "POSTGRES_PASSWORD=$password" -p 127.0.0.1::5432 -p 127.0.0.1::3000 postgres:17-alpine)"
trap 'docker rm -f "$container" >/dev/null' EXIT
for attempt in {1..60}; do
  if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "The isolated PostgreSQL container did not become ready." >&2
    exit 1
  fi
  sleep 1
done
port="$(docker port "$container" 5432/tcp)"
export BOOKALOG_TEST_DATABASE_URL="postgresql://postgres:$password@${port}/postgres"
export BOOKALOG_TEST_PG_CONTAINER="$container"
export BOOKALOG_TEST_REST_ADDRESS="$(docker port "$container" 3000/tcp)"
node --test spikes/contracts/*.test.mjs spikes/backends/*.test.mjs
