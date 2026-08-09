#!/usr/bin/env python3
"""Deterministic tests for CI runner network config rendering.

Run: nix-shell -p nix --run 'python3 tests/ci_runner_network_test.py'
     (or: python3 tests/ci_runner_network_test.py  if nix is on PATH)

Evaluates packages/ci-runner-network-lib.nix via `nix eval` — no live firewall.
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
_LIB = os.path.join(_ROOT, "packages", "ci-runner-network-lib.nix")


def _nix_eval(expr: str):
    """Evaluate a Nix expression that returns a string or attrset as JSON."""
    with tempfile.NamedTemporaryFile("w", suffix=".nix", delete=False) as f:
        f.write(expr)
        path = f.name
    try:
        out = subprocess.check_output(
            [
                "nix",
                "eval",
                "--impure",
                "--json",
                "-f",
                path,
            ],
            text=True,
            stderr=subprocess.STDOUT,
        )
        return json.loads(out)
    except subprocess.CalledProcessError as e:
        raise AssertionError(f"nix eval failed:\n{e.output}") from e
    finally:
        os.unlink(path)


def _eval_lib(body: str) -> str:
    expr = textwrap.dedent(
        f"""
        let
          pkgs = import <nixpkgs> {{ }};
          lib = pkgs.lib;
          net = import {_LIB} {{ inherit lib; }};
        in
        {body}
        """
    )
    return _nix_eval(expr)


class TestDnsRendering(unittest.TestCase):
    def test_empty_hosts_still_has_public_forwarders(self):
        xml = _eval_lib("net.renderDnsXml [ ]")
        self.assertIn("<forwarder addr='1.1.1.1'/>", xml)
        self.assertIn("<forwarder addr='8.8.8.8'/>", xml)
        self.assertNotIn("<host ip=", xml)

    def test_internal_dns_host_entry_renders(self):
        xml = _eval_lib(
            '''
            net.renderDnsXml [
              { name = "homepage.iktstudio.com"; address = "192.168.10.7"; }
            ]
            '''
        )
        self.assertIn("<host ip='192.168.10.7'>", xml)
        self.assertIn("<hostname>homepage.iktstudio.com</hostname>", xml)
        self.assertIn("<forwarder addr='1.1.1.1'/>", xml)

    def test_multiple_names_same_address_grouped(self):
        xml = _eval_lib(
            '''
            net.renderDnsXml [
              { name = "b.example"; address = "10.0.0.2"; }
              { name = "a.example"; address = "10.0.0.2"; }
            ]
            '''
        )
        self.assertEqual(xml.count("<host ip='10.0.0.2'>"), 1)
        self.assertIn("<hostname>a.example</hostname>", xml)
        self.assertIn("<hostname>b.example</hostname>", xml)


class TestFirewallRendering(unittest.TestCase):
    def test_host_allow_tcp_before_semantics(self):
        rules = _eval_lib(
            '''
            net.renderHostAllowRules [
              { address = "192.168.10.7"; port = 443; }
            ]
            '''
        )
        self.assertIn(
            "iptables -A ci-runner-in -d 192.168.10.7 -p tcp --dport 443 -j ACCEPT",
            rules,
        )
        self.assertNotIn("REJECT", rules)

    def test_empty_host_allow_preserves_isolation(self):
        rules = _eval_lib("net.renderHostAllowRules [ ]")
        self.assertEqual(rules, "")

    def test_forward_allowlist_distinct_from_input(self):
        fwd = _eval_lib(
            '''
            net.renderFwdAllowRules "192.168.67.0/24" [
              { address = "10.9.9.9"; port = 8443; }
            ]
            '''
        )
        host = _eval_lib(
            '''
            net.renderHostAllowRules [
              { address = "192.168.10.7"; port = 443; }
            ]
            '''
        )
        self.assertIn("ci-runner-fwd", fwd)
        self.assertNotIn("ci-runner-in", fwd)
        self.assertIn("ci-runner-in", host)
        self.assertNotIn("ci-runner-fwd", host)

    def test_unrelated_ports_not_opened_by_host_allow(self):
        rules = _eval_lib(
            '''
            net.renderHostAllowRules [
              { address = "192.168.10.7"; port = 443; }
            ]
            '''
        )
        self.assertNotIn("--dport 22", rules)
        self.assertNotIn("--dport 80", rules)
        self.assertNotIn("--dport 3000", rules)

    def test_gateway_dns_allow_is_gateway_scoped(self):
        rules = _eval_lib('net.renderGatewayDnsAllowRules "192.168.67.1"')
        self.assertIn("-d 192.168.67.1 -p udp --dport 53 -j ACCEPT", rules)
        self.assertIn("-d 192.168.67.1 -p tcp --dport 53 -j ACCEPT", rules)
        self.assertNotIn("192.168.10.7", rules)


if __name__ == "__main__":
    unittest.main()
