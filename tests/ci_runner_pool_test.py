#!/usr/bin/env python3
"""Deterministic tests for the CI runner pool planner (packages/ci-runner-pool.py).

Run: python3 tests/ci_runner_pool_test.py

Covers the scaling arithmetic (Section 21 scenarios), the explicit pool state
model, the fail-closed GitHub-outage behaviour, and the candidate/foreign-domain
exclusion safety boundary. No external dependencies (stdlib unittest only).
"""

import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_POOL = os.path.join(_HERE, "..", "packages", "ci-runner-pool.py")
_spec = importlib.util.spec_from_file_location("ci_runner_pool", _POOL)
pool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pool)

PREFIX = "ci-ephemeral-"
CAND = "ci-candidate-"


def cfg(desired_idle=1, max_guests=10, grace=300):
    return {
        "prefix": PREFIX,
        "candidate_prefix": CAND,
        "desired_idle": desired_idle,
        "max_guests": max_guests,
        "provisioning_grace_sec": grace,
    }


def dom(name, state="running", created_at=1000):
    return {"name": name, "libvirt_state": state, "created_at": created_at}


def gh(name, status="online", busy=False):
    return {"name": name, "status": status, "busy": busy}


class TestComputeToProvision(unittest.TestCase):
    """Section 21: pure scaling arithmetic (desired_idle=1, max_guests=10)."""

    def _p(self, idle, total, github_ok=True):
        return pool.compute_to_provision(1, 10, idle, total, github_ok)

    def test_empty_pool_provisions_one(self):
        self.assertEqual(self._p(idle=0, total=0), 1)

    def test_one_idle_provisions_none(self):
        self.assertEqual(self._p(idle=1, total=1), 0)

    def test_one_busy_zero_idle_provisions_one(self):
        self.assertEqual(self._p(idle=0, total=1), 1)

    def test_five_busy_one_idle_provisions_none(self):
        self.assertEqual(self._p(idle=1, total=6), 0)

    def test_five_busy_zero_idle_provisions_one(self):
        self.assertEqual(self._p(idle=0, total=5), 1)

    def test_nine_busy_zero_idle_provisions_one(self):
        self.assertEqual(self._p(idle=0, total=9), 1)

    def test_ten_busy_zero_idle_provisions_none(self):
        self.assertEqual(self._p(idle=0, total=10), 0)

    def test_eight_busy_two_provisioning_provisions_none(self):
        # 8 busy + 2 provisioning = total 10 -> at max, no more.
        self.assertEqual(self._p(idle=0, total=10), 0)

    def test_provisioning_counts_toward_idle_supply(self):
        # One guest already booting should satisfy desiredIdle=1.
        self.assertEqual(pool.compute_to_provision(
            1, 10, idle=0, total=1, github_ok=True, provisioning=1), 0)

    def test_github_unavailable_never_provisions(self):
        self.assertEqual(self._p(idle=0, total=0, github_ok=False), 0)

    def test_never_exceeds_remaining_capacity(self):
        # Large idle deficit but only 1 slot left.
        self.assertEqual(pool.compute_to_provision(5, 10, idle=0, total=9,
                                                   github_ok=True), 1)

    def test_higher_desired_idle(self):
        self.assertEqual(pool.compute_to_provision(3, 10, idle=1, total=1,
                                                   github_ok=True), 2)


class TestLiveHostCeiling(unittest.TestCase):
    """Live host evidence-based ceiling: desired_idle=1, max_guests=3."""

    def _plan(self, domains, runners, max_guests=3):
        return pool.classify_domains(
            cfg(desired_idle=1, max_guests=max_guests),
            domains, runners, github_ok=True, now=2000)

    def test_zero_busy_one_idle_provisions_none(self):
        p = self._plan([dom(PREFIX + "a")], [gh(PREFIX + "a", busy=False)])
        self.assertEqual(p["counts"]["busy"], 0)
        self.assertEqual(p["counts"]["idle"], 1)
        self.assertEqual(p["counts"]["total"], 1)
        self.assertEqual(p["provision"], 0)
        self.assertFalse(p["saturated"])

    def test_one_busy_zero_idle_provisions_one(self):
        p = self._plan([dom(PREFIX + "a")], [gh(PREFIX + "a", busy=True)])
        self.assertEqual(p["counts"]["busy"], 1)
        self.assertEqual(p["counts"]["idle"], 0)
        self.assertEqual(p["counts"]["total"], 1)
        self.assertEqual(p["provision"], 1)
        self.assertFalse(p["saturated"])

    def test_one_busy_one_idle_provisions_none(self):
        p = self._plan(
            [dom(PREFIX + "a"), dom(PREFIX + "b")],
            [gh(PREFIX + "a", busy=True), gh(PREFIX + "b", busy=False)])
        self.assertEqual(p["counts"]["busy"], 1)
        self.assertEqual(p["counts"]["idle"], 1)
        self.assertEqual(p["counts"]["total"], 2)
        self.assertEqual(p["provision"], 0)

    def test_two_busy_zero_idle_total_two_provisions_one(self):
        p = self._plan(
            [dom(PREFIX + "a"), dom(PREFIX + "b")],
            [gh(PREFIX + "a", busy=True), gh(PREFIX + "b", busy=True)])
        self.assertEqual(p["counts"]["busy"], 2)
        self.assertEqual(p["counts"]["idle"], 0)
        self.assertEqual(p["counts"]["total"], 2)
        self.assertEqual(p["provision"], 1)

    def test_two_busy_one_idle_total_three_provisions_none(self):
        p = self._plan(
            [dom(PREFIX + "a"), dom(PREFIX + "b"), dom(PREFIX + "c")],
            [gh(PREFIX + "a", busy=True), gh(PREFIX + "b", busy=True),
             gh(PREFIX + "c", busy=False)])
        self.assertEqual(p["counts"]["busy"], 2)
        self.assertEqual(p["counts"]["idle"], 1)
        self.assertEqual(p["counts"]["total"], 3)
        self.assertEqual(p["provision"], 0)
        self.assertFalse(p["saturated"])

    def test_three_busy_saturated_provisions_none(self):
        p = self._plan(
            [dom(PREFIX + "a"), dom(PREFIX + "b"), dom(PREFIX + "c")],
            [gh(PREFIX + "a", busy=True), gh(PREFIX + "b", busy=True),
             gh(PREFIX + "c", busy=True)])
        self.assertEqual(p["counts"]["busy"], 3)
        self.assertEqual(p["counts"]["idle"], 0)
        self.assertEqual(p["counts"]["total"], 3)
        self.assertEqual(p["provision"], 0)
        self.assertTrue(p["saturated"])


class TestClassify(unittest.TestCase):
    def test_initial_idle_spare(self):
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a")],
            [gh(PREFIX + "a", busy=False)],
            github_ok=True, now=2000)
        self.assertEqual(p["counts"]["idle"], 1)
        self.assertEqual(p["counts"]["busy"], 0)
        self.assertEqual(p["counts"]["total"], 1)
        self.assertEqual(p["provision"], 0)
        self.assertFalse(p["saturated"])

    def test_one_busy_triggers_replacement(self):
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a")],
            [gh(PREFIX + "a", busy=True)],
            github_ok=True, now=2000)
        self.assertEqual(p["counts"]["busy"], 1)
        self.assertEqual(p["counts"]["idle"], 0)
        self.assertEqual(p["counts"]["total"], 1)
        self.assertEqual(p["provision"], 1)  # start runner-2

    def test_busy_plus_new_idle(self):
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a"), dom(PREFIX + "b")],
            [gh(PREFIX + "a", busy=True), gh(PREFIX + "b", busy=False)],
            github_ok=True, now=2000)
        self.assertEqual(p["counts"]["busy"], 1)
        self.assertEqual(p["counts"]["idle"], 1)
        self.assertEqual(p["counts"]["total"], 2)
        self.assertEqual(p["provision"], 0)

    def test_saturated_all_busy(self):
        domains = [dom(PREFIX + str(i)) for i in range(10)]
        runners = [gh(PREFIX + str(i), busy=True) for i in range(10)]
        p = pool.classify_domains(cfg(), domains, runners,
                                  github_ok=True, now=2000)
        self.assertEqual(p["counts"]["busy"], 10)
        self.assertEqual(p["counts"]["total"], 10)
        self.assertEqual(p["provision"], 0)   # never create runner 11
        self.assertTrue(p["saturated"])

    def test_shut_off_guest_is_stale_and_destroyed(self):
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a", state="shut off")],
            [],
            github_ok=True, now=2000)
        self.assertIn(PREFIX + "a", p["destroy"])
        self.assertEqual(p["classify"][PREFIX + "a"], pool.STALE)
        self.assertEqual(p["counts"]["total"], 0)
        self.assertEqual(p["provision"], 1)  # replace the drained guest

    def test_in_shutdown_guest_is_shutting_down(self):
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a", state="in shutdown")],
            [gh(PREFIX + "a", busy=True)],
            github_ok=True, now=2000)
        self.assertEqual(p["classify"][PREFIX + "a"], pool.SHUTTING_DOWN)
        self.assertIn(PREFIX + "a", p["destroy"])
        self.assertEqual(p["counts"]["total"], 0)

    def test_recently_provisioned_within_grace(self):
        p = pool.classify_domains(
            cfg(grace=300),
            [dom(PREFIX + "a", created_at=1900)],  # age 100s
            [],  # not yet registered
            github_ok=True, now=2000)
        self.assertEqual(p["classify"][PREFIX + "a"], pool.PROVISIONING)
        self.assertNotIn(PREFIX + "a", p["destroy"])
        self.assertEqual(p["counts"]["total"], 1)
        self.assertEqual(p["provision"], 0)  # provisioning counts toward idle goal

    def test_stuck_provisioning_past_grace_is_uncertain_destroyed(self):
        p = pool.classify_domains(
            cfg(grace=300),
            [dom(PREFIX + "a", created_at=1000)],  # age 1000s
            [],  # never registered
            github_ok=True, now=2000)
        self.assertEqual(p["classify"][PREFIX + "a"], pool.UNCERTAIN)
        self.assertIn(PREFIX + "a", p["destroy"])
        self.assertEqual(p["counts"]["total"], 0)
        self.assertEqual(p["provision"], 1)

    def test_offline_runner_past_grace_destroyed(self):
        p = pool.classify_domains(
            cfg(grace=300),
            [dom(PREFIX + "a", created_at=1000)],
            [gh(PREFIX + "a", status="offline")],
            github_ok=True, now=2000)
        self.assertIn(PREFIX + "a", p["destroy"])

    def test_github_outage_retains_running_guests_no_provision(self):
        # 2 running guests, GitHub unreachable: keep them, provision nothing.
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a"), dom(PREFIX + "b")],
            [],
            github_ok=False, now=2000)
        self.assertEqual(p["counts"]["uncertain"], 2)
        self.assertEqual(p["counts"]["total"], 2)
        self.assertEqual(p["destroy"], [])
        self.assertEqual(p["provision"], 0)

    def test_github_outage_still_reaps_shutoff(self):
        # A shut-off guest is unambiguous locally: destroy even during outage.
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a", state="shut off")],
            [],
            github_ok=False, now=2000)
        self.assertIn(PREFIX + "a", p["destroy"])
        self.assertEqual(p["provision"], 0)

    def test_candidate_and_foreign_domains_excluded(self):
        # Candidate VM + Home Assistant must be invisible to the production pool.
        p = pool.classify_domains(
            cfg(),
            [
                dom(PREFIX + "a"),
                dom(CAND + "x"),
                dom("homeassistant"),
            ],
            [gh(PREFIX + "a", busy=False), gh(CAND + "x", busy=True)],
            github_ok=True, now=2000)
        self.assertEqual(p["counts"]["total"], 1)  # only ci-ephemeral-a
        self.assertNotIn(CAND + "x", p["classify"])
        self.assertNotIn("homeassistant", p["classify"])
        self.assertNotIn(CAND + "x", p["destroy"])
        self.assertNotIn("homeassistant", p["destroy"])

    def test_max_invariant_never_exceeded_with_mixed_states(self):
        # 9 busy + 1 idle + 1 stale(shut off): total after cleanup = 10, no new.
        domains = [dom(PREFIX + str(i)) for i in range(9)]
        runners = [gh(PREFIX + str(i), busy=True) for i in range(9)]
        domains.append(dom(PREFIX + "idle"))
        runners.append(gh(PREFIX + "idle", busy=False))
        domains.append(dom(PREFIX + "dead", state="shut off"))
        p = pool.classify_domains(cfg(), domains, runners,
                                  github_ok=True, now=2000)
        self.assertEqual(p["counts"]["total"], 10)
        self.assertEqual(p["counts"]["busy"], 9)
        self.assertEqual(p["counts"]["idle"], 1)
        self.assertIn(PREFIX + "dead", p["destroy"])
        self.assertEqual(p["provision"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
