#!/usr/bin/env bash
# Guest-local Playwright Chromium smoke (run inside disposable CI guest / Actions job).
# Uses runtime-installed @playwright/test — does NOT bake Playwright into the guest image.
# HTTP fixture uses Node (from setup-node), not Python.
# Usage: bash fixtures/ci-runner-e2e/playwright-smoke.sh
#
# Default PLAYWRIGHT_VERSION is the current stable validated in this correction pass
# (npm registry @playwright/test latest = 1.62.1 as of 2026-08-10). Override to pin
# another explicit version; do not use an unqualified "latest" in CI evidence.
set -euo pipefail
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"

PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.62.1}"

echo "== node toolchain (repo-owned; setup-node may have configured this) =="
command -v node
node --version
command -v npm
npm --version

echo "== install @playwright/test@${PLAYWRIGHT_VERSION} at runtime =="
npm init -y >/dev/null
npm install --no-save "@playwright/test@${PLAYWRIGHT_VERSION}"

echo "== playwright install chromium (no --with-deps) =="
export DEBUG="${DEBUG:-pw:browser}"
npx playwright install chromium

# Record exact package + browser revision for acceptance evidence.
PW_PKG_VER="$(node -e "console.log(require('@playwright/test/package.json').version)")"
echo "playwright package version: $PW_PKG_VER"
# Chromium revision directory under the Playwright cache (best-effort).
if [[ -d "${HOME}/.cache/ms-playwright" ]]; then
  echo "ms-playwright cache entries:"
  ls -1 "${HOME}/.cache/ms-playwright" || true
fi

echo "== local HTTP fixture (node) =="
cat > server.mjs <<'JS'
import http from 'node:http';
const body = '<html><body><h1>ci-runner-playwright-ok</h1></body></html>';
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}).listen(8765, '127.0.0.1', () => console.log('http fixture listening'));
JS
node server.mjs &
SERVER_PID=$!
sleep 0.5

echo "== headless chromium assertion =="
cat > smoke.mjs <<'JS'
import { chromium } from '@playwright/test';
const browser = await chromium.launch({ headless: true });
const version = browser.version();
console.log('chromium browser.version():', version);
const page = await browser.newPage();
await page.goto('http://127.0.0.1:8765/', { waitUntil: 'domcontentloaded' });
const text = await page.locator('h1').innerText();
if (text !== 'ci-runner-playwright-ok') {
  console.error('unexpected text:', text);
  process.exit(1);
}
console.log('playwright assertion ok:', text);
await browser.close();
JS
node smoke.mjs

echo "playwright smoke: PASS (version=${PW_PKG_VER})"
