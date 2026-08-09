#!/usr/bin/env bash
# Guest-local Podman compose smoke (run inside disposable CI guest / Actions job).
# Usage: bash fixtures/ci-runner-e2e/podman-smoke.sh
# No Python — guest does not bake application interpreters.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "== podman info =="
podman info >/dev/null
echo "podman info: ok"

echo "== podman compose version =="
podman compose version

echo "== compose up --wait =="
podman compose -f compose.yaml up -d --wait

echo "== loopback probes =="
# postgres: healthchecked container + TCP on published loopback
podman exec ci-runner-e2e_postgres_1 pg_isready -U ci -d ci
timeout 5 bash -c 'echo >/dev/tcp/127.0.0.1/5432'
# redis: use redis-cli inside the container + TCP on published loopback
pong="$(podman exec ci-runner-e2e_redis_1 redis-cli ping)"
[[ "$pong" == "PONG" ]] || { echo "FAIL: redis ping got: $pong"; exit 1; }
timeout 5 bash -c 'echo >/dev/tcp/127.0.0.1/6379'
echo "postgres/redis loopback: ok"

echo "== compose down -v =="
podman compose -f compose.yaml down -v
# Project containers should be gone
if podman ps -a --format '{{.Names}}' | grep -E 'ci-runner-e2e_(postgres|redis)_' >/dev/null 2>&1; then
  echo "FAIL: containers still present after down -v"
  podman ps -a
  exit 1
fi
echo "podman smoke: PASS"
