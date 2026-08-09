#!/usr/bin/env bash
# Failure-path Compose cleanup proof for disposable CI guests.
#
# Exercises the same EXIT-trap model as podman-smoke.sh / combined-smoke.sh:
# project-scoped `down -v` must run even when the workload exits before the
# explicit successful teardown proof (including when `up -d --wait` itself fails
# after creating project resources).
#
# Expected: this script exits 0 only when intentional failures were observed
# AND project containers + named volumes were removed by EXIT cleanup.
# Project-scoped teardown only (never a global Podman prune).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PROJECT=ci-runner-e2e-fail
COMPOSE_FILE="$ROOT/compose.yaml"
COMPOSE=(podman compose -p "$PROJECT" -f "$COMPOSE_FILE")
EXPECTED_VOLUMES=(
  "${PROJECT}_pgdata"
  "${PROJECT}_redisdata"
)

compose_down() {
  "${COMPOSE[@]}" down -v "$@"
}

assert_project_gone() {
  local vol names
  names="$(podman ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -n "$names" ]]; then
    echo "FAIL: project containers still present: $names"
    podman ps -a || true
    return 1
  fi
  if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PROJECT}_(postgres|redis)_" >/dev/null 2>&1; then
    echo "FAIL: containers still present by name pattern"
    podman ps -a || true
    return 1
  fi
  for vol in "${EXPECTED_VOLUMES[@]}"; do
    if podman volume exists "$vol" 2>/dev/null; then
      echo "FAIL: fixture-owned volume still present: $vol"
      podman volume ls || true
      return 1
    fi
  done
}

# Ensure no leftover project state from a prior aborted run.
compose_down >/dev/null 2>&1 || true

echo "== failure path 1: intentional fail after successful up =="
# Subshell: EXIT trap must clean up when we exit 42 before VOLUME_PROOF_DONE=1.
set +e
(
  set -euo pipefail
  VOLUME_PROOF_DONE=0
  cleanup_on_exit() {
    if [[ "$VOLUME_PROOF_DONE" -eq 0 ]]; then
      compose_down >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_on_exit EXIT
  "${COMPOSE[@]}" up -d --wait
  for vol in "${EXPECTED_VOLUMES[@]}"; do
    podman volume exists "$vol"
  done
  echo "intentional failure after compose up (exit 42)"
  exit 42
)
rc1=$?
set -e
if [[ "$rc1" -ne 42 ]]; then
  echo "FAIL: expected intentional exit 42, got $rc1"
  compose_down >/dev/null 2>&1 || true
  exit 1
fi
assert_project_gone
echo "fail-after-up EXIT cleanup: ok (containers + named volumes gone)"

echo "== failure path 2: up -d --wait fails after creating resources =="
# Temporary compose with an impossible healthcheck so --wait fails while
# containers/volumes may already exist. Deleted afterward (not left in fixtures).
FAIL_DIR="$(mktemp -d)"
cleanup_fail_dir() { rm -rf "$FAIL_DIR"; }
trap cleanup_fail_dir EXIT
cat >"$FAIL_DIR/compose.yaml" <<'YAML'
# Ephemeral failure-path fixture — never committed; removed by EXIT.
name: ci-runner-e2e-fail
services:
  postgres:
    image: docker.io/library/postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ci
      POSTGRES_USER: ci
      POSTGRES_DB: ci
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "exit 1"]
      interval: 1s
      timeout: 1s
      retries: 3
      start_period: 0s
  redis:
    image: docker.io/library/redis:7-alpine
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD-SHELL", "exit 1"]
      interval: 1s
      timeout: 1s
      retries: 3
      start_period: 0s
volumes:
  pgdata:
  redisdata:
YAML

FAIL_COMPOSE=(podman compose -p "$PROJECT" -f "$FAIL_DIR/compose.yaml")
fail_compose_down() {
  "${FAIL_COMPOSE[@]}" down -v "$@"
}
fail_compose_down >/dev/null 2>&1 || true

set +e
(
  set -euo pipefail
  VOLUME_PROOF_DONE=0
  cleanup_on_exit() {
    if [[ "$VOLUME_PROOF_DONE" -eq 0 ]]; then
      fail_compose_down >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_on_exit EXIT
  # Expected to fail (healthchecks never succeed).
  # Bound wait so a stuck health-wait cannot hang the disposable guest forever.
  timeout 60 "${FAIL_COMPOSE[@]}" up -d --wait
  echo "FAIL: up -d --wait unexpectedly succeeded"
  exit 99
)
rc2=$?
set -e
if [[ "$rc2" -eq 0 || "$rc2" -eq 99 ]]; then
  echo "FAIL: expected non-zero up --wait failure, got $rc2"
  fail_compose_down >/dev/null 2>&1 || true
  exit 1
fi
echo "up -d --wait failed as intended (rc=$rc2)"
assert_project_gone
echo "fail-during-up EXIT cleanup: ok (containers + named volumes gone)"

# Drop the temp-dir EXIT trap; outer assert already passed.
trap - EXIT
rm -rf "$FAIL_DIR"

echo "podman failure-path cleanup smoke: PASS"
