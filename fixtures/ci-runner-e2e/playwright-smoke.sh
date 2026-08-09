#!/usr/bin/env bash
# Guest-local Playwright Chromium smoke (run inside disposable CI guest / Actions job).
# Uses runtime-installed @playwright/test — does NOT bake Playwright into the guest image.
# HTTP fixture uses Node (from setup-node), not Python.
# Usage: bash fixtures/ci-runner-e2e/playwright-smoke.sh
set -euo pipefail
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "== node toolchain (repo-owned; setup-node may have configured this) =="
command -v node
node --version
command -v npm
npm --version

echo "== install @playwright/test at runtime =="
npm init -y >/dev/null
npm install --no-save @playwright/test@1.55.0

echo "== playwright install chromium (no --with-deps) =="
export DEBUG="${DEBUG:-pw:browser}"
npx playwright install chromium

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
trap 'kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
sleep 0.5

echo "== headless chromium assertion =="
cat > smoke.mjs <<'JS'
import { chromium } from '@playwright/test';
const browser = await chromium.launch({ headless: true });
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

echo "playwright smoke: PASS"
