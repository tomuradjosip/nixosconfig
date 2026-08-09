#!/usr/bin/env bash
# Combined Podman + Node HTTP + Playwright Chromium workload for candidate validation.
# Representative of Shopforge TASK-013 platform needs (not the Shopforge app itself).
# No Python dependency.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PROJECT=ci-runner-e2e
COMPOSE=(podman compose -p "$PROJECT" -f compose.yaml)
COMPOSE_STARTED=0
VOLUME_PROOF_DONE=0

EXPECTED_VOLUMES=(
  "${PROJECT}_pgdata"
  "${PROJECT}_redisdata"
)

# Best-effort peak memory via cgroup v2 (kernel-backed) when available.
read_memory_peak() {
  local f
  for f in /sys/fs/cgroup/memory.peak \
           /sys/fs/cgroup/system.slice/memory.peak \
           /sys/fs/cgroup/$(cat /proc/self/cgroup 2>/dev/null | head -n1 | cut -d: -f3)/memory.peak; do
    if [[ -r "$f" ]]; then
      echo "memory.peak_bytes@$f=$(cat "$f")"
      return 0
    fi
  done
  # Walk up from self cgroup
  local cg
  cg="$(awk -F: 'NR==1{print $3}' /proc/self/cgroup 2>/dev/null || true)"
  if [[ -n "$cg" && -r "/sys/fs/cgroup${cg}/memory.peak" ]]; then
    echo "memory.peak_bytes=/sys/fs/cgroup${cg}/memory.peak=$(cat "/sys/fs/cgroup${cg}/memory.peak")"
    return 0
  fi
  echo "memory.peak: unavailable"
  return 0
}

resource_snapshot() {
  local label="$1"
  echo "== resource ${label} =="
  free -m || true
  df -h / /tmp || true
  nproc || true
  read_memory_peak || true
  du -sh "${HOME}/.cache/ms-playwright" 2>/dev/null || true
  podman system df 2>/dev/null || true
}

compose_down() {
  "${COMPOSE[@]}" down -v "$@"
}

assert_project_gone() {
  local vol names
  names="$(podman ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -n "$names" ]]; then
    echo "FAIL: project containers still present: $names"
    return 1
  fi
  if podman ps -a --format '{{.Names}}' | grep -E "^${PROJECT}_(postgres|redis)_" >/dev/null 2>&1; then
    echo "FAIL: containers still present after down -v"
    podman ps -a
    return 1
  fi
  for vol in "${EXPECTED_VOLUMES[@]}"; do
    if podman volume exists "$vol" 2>/dev/null; then
      echo "FAIL: fixture-owned volume still present after down -v: $vol"
      podman volume ls
      return 1
    fi
  done
}

cleanup_on_exit() {
  if [[ "$COMPOSE_STARTED" -eq 1 && "$VOLUME_PROOF_DONE" -eq 0 ]]; then
    compose_down >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_exit EXIT

resource_snapshot "baseline"

# Standalone podman smoke proves up/--wait/loopback/down -v (including named volumes).
bash "$ROOT/podman-smoke.sh"

# Re-start compose for the combined browser path (podman-smoke tears down).
echo "== compose up for combined path =="
"${COMPOSE[@]}" up -d --wait
COMPOSE_STARTED=1
timeout 5 bash -c 'echo >/dev/tcp/127.0.0.1/5432'
REDIS_CTR="$(podman ps --filter "label=com.docker.compose.project=${PROJECT}" --filter "label=com.docker.compose.service=redis" --format '{{.Names}}' | head -n1)"
REDIS_CTR="${REDIS_CTR:-${PROJECT}_redis_1}"
podman exec "$REDIS_CTR" redis-cli ping | grep -q PONG

# Playwright smoke owns its local Node HTTP server + EXIT kill trap.
bash "$ROOT/playwright-smoke.sh"

resource_snapshot "after browser"

echo "== compose down -v (combined explicit volume-removal proof) =="
compose_down
VOLUME_PROOF_DONE=1
assert_project_gone
echo "project containers and named volumes removed: ok"

resource_snapshot "after teardown"
echo "combined smoke: PASS"
