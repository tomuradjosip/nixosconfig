#!/usr/bin/env python3
"""Deterministic tests for disposable CI guest capability configuration.

Run: python3 tests/ci_runner_guest_test.py

Evaluates modules/ci-runner-guest.nix (with the same unstable overlays as the
image build) and asserts Podman / Compose / Docker / SSH / nix-ld Chromium
runtime / no-application-toolchain invariants. No live VM required.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import textwrap
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
_GUEST_MODULE = os.path.join(_ROOT, "modules", "ci-runner-guest.nix")


def _nix_eval_json(expr: str):
    with tempfile.NamedTemporaryFile("w", suffix=".nix", delete=False) as f:
        f.write(expr)
        path = f.name
    try:
        proc = subprocess.run(
            [
                "nix",
                "eval",
                "--impure",
                "--json",
                "-f",
                path,
            ],
            text=True,
            capture_output=True,
            cwd=_ROOT,
            check=False,
        )
        if proc.returncode != 0:
            raise AssertionError(
                f"nix eval failed (rc={proc.returncode}):\n"
                f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            )
        # Warnings (e.g. dirty Git tree) go to stderr; stdout must be pure JSON.
        return json.loads(proc.stdout)
    finally:
        os.unlink(path)


def _eval_guest(body: str):
    """Evaluate `body` with `cfg` bound to the guest module config."""
    expr = textwrap.dedent(
        f"""
        let
          flake = builtins.getFlake "git+file://{_ROOT}";
          system = "x86_64-linux";
          guestPkgs = import flake.inputs.nixpkgs-guest {{ inherit system; }};
          unstablePkgs = import flake.inputs.nixpkgs-unstable {{ inherit system; }};
          pkgsGuest = guestPkgs.extend (_final: _prev: {{
            github-runner = unstablePkgs.github-runner;
            podman-compose = unstablePkgs.podman-compose;
          }});
          eval = import (guestPkgs.path + "/nixos/lib/eval-config.nix") {{
            inherit system;
            modules = [
              {_GUEST_MODULE}
              {{
                nixpkgs.pkgs = pkgsGuest;
                documentation.enable = false;
              }}
            ];
          }};
          cfg = eval.config;
          pkgs = pkgsGuest;
        in
        {body}
        """
    )
    return _nix_eval_json(expr)


class TestGuestPodman(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.caps = _eval_guest(
            """
            {
              podmanEnable = cfg.virtualisation.podman.enable;
              dockerEnable = cfg.virtualisation.docker.enable;
              dockerCompat = cfg.virtualisation.podman.dockerCompat;
              dockerSocket = cfg.virtualisation.podman.dockerSocket.enable;
              sshEnable = cfg.services.openssh.enable;
              composeProvider = builtins.head
                cfg.virtualisation.containers.containersConf.settings.engine.compose_providers;
              composeVersion = pkgs.podman-compose.version;
              runnerPodmanComposeEnv =
                cfg.systemd.services.ci-runner-lifecycle.environment.PODMAN_COMPOSE_PROVIDER;
              nixLdEnable = cfg.programs.nix-ld.enable;
            }
            """
        )

    def test_podman_enabled(self):
        self.assertTrue(self.caps["podmanEnable"])

    def test_docker_engine_disabled(self):
        self.assertFalse(self.caps["dockerEnable"])

    def test_docker_compat_disabled(self):
        self.assertFalse(self.caps["dockerCompat"])

    def test_docker_socket_compat_disabled(self):
        self.assertFalse(self.caps["dockerSocket"])

    def test_ssh_disabled(self):
        self.assertFalse(self.caps["sshEnable"])

    def test_compose_provider_is_podman_compose(self):
        provider = self.caps["composeProvider"]
        self.assertIn("podman-compose", provider)
        self.assertEqual(provider, self.caps["runnerPodmanComposeEnv"])

    def test_compose_version_supports_wait(self):
        # 1.6.0+ required for `podman compose up -d --wait`
        version = self.caps["composeVersion"]
        parts = [int(x) for x in version.split(".")[:3]]
        self.assertGreaterEqual(parts, [1, 6, 0], f"podman-compose {version} too old")


class TestGuestPlaywrightRuntime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.libs = _eval_guest(
            """
            map (p: p.pname or p.name) cfg.programs.nix-ld.libraries
            """
        )
        cls.fonts = _eval_guest(
            """
            map (p: p.pname or p.name) cfg.fonts.packages
            """
        )
        cls.env = _eval_guest(
            """
            {
              nixLd = cfg.systemd.services.ci-runner-lifecycle.environment.NIX_LD;
              nixLdPath = cfg.systemd.services.ci-runner-lifecycle.environment.NIX_LD_LIBRARY_PATH;
            }
            """
        )

    def test_nix_ld_exported_to_runner(self):
        self.assertIn("nix-ld", self.env["nixLd"])
        self.assertIn("nix-ld", self.env["nixLdPath"])

    def test_chromium_runtime_libraries_present(self):
        # Match case-insensitively: pname orthography varies (libX11 vs libx11,
        # libgbm vs mesa-libgbm). ATK / at-spi2-atk alias to at-spi2-core on 26.05+.
        joined = " ".join(self.libs).lower()
        required = [
            "alsa-lib",
            "at-spi2-core",
            "cairo",
            "cups",
            "dbus",
            "fontconfig",
            "freetype",
            "glib",
            "libdrm",
            "libgbm",
            "libxkbcommon",
            "nspr",
            "nss",
            "pango",
            "libx11",
            "libxcb",
        ]
        missing = [name for name in required if name not in joined]
        self.assertEqual(missing, [], f"missing nix-ld libs: {missing}; have: {self.libs}")

    def test_basic_fonts_present(self):
        joined = " ".join(self.fonts)
        self.assertTrue(
            "liberation" in joined.lower() or "dejavu" in joined.lower(),
            f"expected basic fonts, got {self.fonts}",
        )


class TestGuestNoApplicationToolchainPin(unittest.TestCase):
    def test_system_packages_exclude_app_toolchains(self):
        names = _eval_guest(
            """
            map (p: p.pname or p.name or "") cfg.environment.systemPackages
            """
        )
        joined = " ".join(names).lower()
        # nodejs / pnpm / playwright / chromium / medusa must not appear as packages.
        hard = [f for f in ("nodejs", "pnpm", "corepack", "playwright", "chromium", "medusa") if f in joined]
        self.assertEqual(hard, [], f"application toolchain packages leaked into guest: {hard}")
        # docker-compose binary must not be present (would steal compose provider precedence)
        self.assertNotIn("docker-compose", joined)


class TestGuestRunnerPath(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = _eval_guest(
            """
            map (p: p.pname or p.name or "") cfg.systemd.services.ci-runner-lifecycle.path
            """
        )

    def test_procps_on_runner_path(self):
        # free/ps for guest resource measurements in CI jobs (added in 0889c5d).
        joined = " ".join(self.path).lower()
        self.assertTrue(
            "procps" in joined,
            f"expected procps on runner PATH for free/ps; got: {self.path}",
        )

    def test_podman_and_compose_on_runner_path(self):
        joined = " ".join(self.path).lower()
        self.assertIn("podman", joined)
        self.assertIn("podman-compose", joined)


class TestE2EFixtureContracts(unittest.TestCase):
    """Static checks on fixtures/ci-runner-e2e (no live Podman required)."""

    _FIXTURES = os.path.join(_ROOT, "fixtures", "ci-runner-e2e")

    def _read(self, name: str) -> str:
        with open(os.path.join(self._FIXTURES, name), encoding="utf-8") as f:
            return f.read()

    def test_compose_uses_named_postgres_volume(self):
        text = self._read("compose.yaml")
        self.assertIn("pgdata:/var/lib/postgresql/data", text)
        self.assertIn("volumes:", text)
        self.assertIn("pgdata:", text)

    def test_podman_smoke_proves_volume_removal(self):
        text = self._read("podman-smoke.sh")
        self.assertIn("down -v", text)
        self.assertIn("podman volume exists", text)
        self.assertIn("EXPECTED_VOLUMES", text)
        self.assertIn("trap cleanup_on_exit EXIT", text)

    def test_podman_smoke_cleans_up_even_when_up_wait_fails(self):
        """EXIT trap must not gate on COMPOSE_STARTED=1 after a successful up.

        `up -d --wait` can create containers/volumes then fail (e.g. health timeout).
        With set -e that exits before any post-up flag; cleanup must still run.
        """
        text = self._read("podman-smoke.sh")
        self.assertIn("VOLUME_PROOF_DONE", text)
        self.assertIn('if [[ "$VOLUME_PROOF_DONE" -eq 0 ]]; then', text)
        # Must not gate EXIT cleanup on a post-up success flag (the prior bug).
        self.assertNotRegex(text, r"\bCOMPOSE_STARTED\b")
        self.assertIn("compose_down >/dev/null 2>&1 || true", text)

    def test_playwright_smoke_pins_current_stable_default(self):
        text = self._read("playwright-smoke.sh")
        self.assertIn('PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.62.1}"', text)
        self.assertIn('npm install --no-save "@playwright/test@${PLAYWRIGHT_VERSION}"', text)
        self.assertIn("npx playwright install chromium", text)
        # Install command must not use --with-deps (comment may mention the ban).
        self.assertNotRegex(text, r"npx playwright install[^\n]*--with-deps")
        self.assertNotIn("@playwright/test@1.55.0", text)

    def test_combined_smoke_has_cleanup_trap(self):
        text = self._read("combined-smoke.sh")
        self.assertIn("trap cleanup_on_exit EXIT", text)
        self.assertIn("VOLUME_PROOF_DONE", text)
        self.assertIn("read_memory_peak", text)
        self.assertIn('if [[ "$VOLUME_PROOF_DONE" -eq 0 ]]; then', text)
        self.assertNotRegex(text, r"\bCOMPOSE_STARTED\b")

    def test_failure_cleanup_smoke_exercises_exit_paths(self):
        text = self._read("podman-failure-cleanup-smoke.sh")
        self.assertIn("intentional failure after compose up", text)
        self.assertIn("up -d --wait", text)
        self.assertIn("exit 42", text)
        self.assertIn("healthcheck:", text)
        self.assertIn('test: ["CMD-SHELL", "exit 1"]', text)
        self.assertIn("assert_project_gone", text)
        self.assertNotRegex(text, r"\bpodman\s+system\s+prune\b")


if __name__ == "__main__":
    unittest.main()
