#!/usr/bin/env bash
# Guest-local Podman compose smoke (run inside disposable CI guest / Actions job).
# Usage: bash fixtures/ci-runner-e2e/podman-smoke.sh
# No Python — guest does not bake application interpreters.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PROJECT=ci-runner-e2e
COMPOSE=(podman compose -p "$PROJECT" -f compose.yaml)
# Set only after the explicit successful down -v + removal assertions complete.
# EXIT cleanup runs whenever this is still 0 — including when `up -d --wait`
# itself fails after partially creating containers/volumes (set -e would
# otherwise exit before any post-up success flag could be set).
VOLUME_PROOF_DONE=0

# Project-scoped named volumes from compose.yaml (not global Podman state).
EXPECTED_VOLUMES=(
  "${PROJECT}_pgdata"
  "${PROJECT}_redisdata"
)

compose_down() {
  "${COMPOSE[@]}" down -v "$@"
}

# Project-scoped teardown if we never completed the explicit volume-removal proof.
# Covers: failed/partial `up -d --wait`, mid-run assertion failures, and interrupts.
# Must not hide the original failure status (bash EXIT traps preserve $?; we never exit here).
cleanup_on_exit() {
  if [[ "$VOLUME_PROOF_DONE" -eq 0 ]]; then
    compose_down >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_exit EXIT

assert_project_containers_gone() {
  local names
  names="$(podman ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -n "$names" ]]; then
    echo "FAIL: project containers still present after down -v:"
    echo "$names"
    podman ps -a
    return 1
  fi
  # Fallback name pattern if labels differ across compose providers
  if podman ps -a --format '{{.Names}}' | grep -E "^${PROJECT}_(postgres|redis)_" >/dev/null 2>&1; then
    echo "FAIL: containers still present after down -v"
    podman ps -a
    return 1
  fi
}

assert_project_volumes_gone() {
  local vol
  for vol in "${EXPECTED_VOLUMES[@]}"; do
    if podman volume exists "$vol" 2>/dev/null; then
      echo "FAIL: fixture-owned volume still present after down -v: $vol"
      podman volume ls
      return 1
    fi
  done
}

echo "== podman info =="
podman info >/dev/null
echo "podman info: ok"

echo "== podman compose version =="
podman compose version

echo "== compose up --wait =="
"${COMPOSE[@]}" up -d --wait

echo "== project named volumes present =="
for vol in "${EXPECTED_VOLUMES[@]}"; do
  if ! podman volume exists "$vol"; then
    echo "FAIL: expected named volume missing after up: $vol"
    podman volume ls
    exit 1
  fi
  echo "volume present: $vol"
done

echo "== loopback probes =="
# Resolve container names via project filter (stable across compose naming).
PG_CTR="$(podman ps --filter "label=com.docker.compose.project=${PROJECT}" --filter "label=com.docker.compose.service=postgres" --format '{{.Names}}' | head -n1)"
REDIS_CTR="$(podman ps --filter "label=com.docker.compose.project=${PROJECT}" --filter "label=com.docker.compose.service=redis" --format '{{.Names}}' | head -n1)"
if [[ -z "$PG_CTR" ]]; then
  PG_CTR="${PROJECT}_postgres_1"
fi
if [[ -z "$REDIS_CTR" ]]; then
  REDIS_CTR="${PROJECT}_redis_1"
fi

podman exec "$PG_CTR" pg_isready -U ci -d ci
timeout 5 bash -c 'echo >/dev/tcp/127.0.0.1/5432'
pong="$(podman exec "$REDIS_CTR" redis-cli ping)"
[[ "$pong" == "PONG" ]] || { echo "FAIL: redis ping got: $pong"; exit 1; }
timeout 5 bash -c 'echo >/dev/tcp/127.0.0.1/6379'
echo "postgres/redis loopback: ok"

echo "== compose down -v (explicit volume-removal proof) =="
compose_down
assert_project_containers_gone
assert_project_volumes_gone
VOLUME_PROOF_DONE=1
echo "project containers and named volumes removed: ok"
echo "podman smoke: PASS"
