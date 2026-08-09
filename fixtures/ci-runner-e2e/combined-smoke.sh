#!/usr/bin/env bash
# Combined Podman + Node HTTP + Playwright Chromium workload for candidate validation.
# Representative of Shopforge TASK-013 platform needs (not the Shopforge app itself).
# No Python dependency.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "== resource baseline =="
free -m || true
df -h / /tmp || true
nproc || true

bash "$ROOT/podman-smoke.sh"

# Re-start compose for the combined browser path (podman-smoke tears down).
podman compose -f compose.yaml up -d --wait
timeout 5 bash -c 'echo >/dev/tcp/127.0.0.1/5432'
podman exec ci-runner-e2e_redis_1 redis-cli ping | grep -q PONG

bash "$ROOT/playwright-smoke.sh"

echo "== resource after browser =="
free -m || true
df -h / /tmp || true
du -sh "${HOME}/.cache/ms-playwright" 2>/dev/null || true
podman system df || true

podman compose -f compose.yaml down -v
echo "combined smoke: PASS"
