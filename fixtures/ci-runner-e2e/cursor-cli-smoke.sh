#!/usr/bin/env bash
# Cursor CLI platform preflight for disposable agent runners.
# Does NOT run an autonomous coding agent. Proves the guest can install a
# pinned Cursor CLI lab build (workflow-owned version) and invoke --help.
#
# Usage (inside a GitHub Actions job on nixos-ephemeral-agent, or manually):
#   CURSOR_CLI_VERSION=2026.08.11-e8db854 bash fixtures/ci-runner-e2e/cursor-cli-smoke.sh
#
# Version ownership: the consuming workflow pins CURSOR_CLI_VERSION. The runner
# image does not bake Cursor CLI (avoids unpinned curl|bash and keeps updates
# in application repos). Official URL scheme from https://cursor.com/install.
set -euo pipefail

VERSION="${CURSOR_CLI_VERSION:?Set CURSOR_CLI_VERSION to a Cursor lab build id (e.g. 2026.08.11-e8db854)}"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "FAIL: unsupported arch $ARCH"; exit 1 ;;
esac

DIR="${HOME}/.local/share/cursor-agent/versions/${VERSION}"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$DIR" "$BIN_DIR"

URL="https://downloads.cursor.com/lab/${VERSION}/linux/${ARCH}/agent-cli-package.tar.gz"
echo "cursor-cli-smoke: downloading pinned $URL"
curl -fsSL "$URL" | tar --strip-components=1 -xz -C "$DIR"
ln -sfn "$DIR/cursor-agent" "$BIN_DIR/agent"
ln -sfn "$DIR/cursor-agent" "$BIN_DIR/cursor-agent"
export PATH="${BIN_DIR}:${PATH}"

echo "cursor-cli-smoke: agent --version"
agent --version
echo "cursor-cli-smoke: agent --help (first lines)"
agent --help | head -n 20
# Auth is job-secret only; do not require CURSOR_API_KEY for this platform check.
if [[ -n "${CURSOR_API_KEY:-}" ]]; then
  echo "cursor-cli-smoke: CURSOR_API_KEY is set (not printing); auth preflight skipped beyond env presence"
else
  echo "cursor-cli-smoke: CURSOR_API_KEY unset (ok for install/help smoke)"
fi
echo "cursor-cli-smoke: PASS"
