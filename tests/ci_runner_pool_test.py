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



AGENT_PREFIX = "agent-ephemeral-"
AGENT_CAND = "agent-candidate-"


def multi_pools():
    return [
        {
            "id": "ci",
            "prefix": PREFIX,
            "candidate_prefix": CAND,
            "desired_idle": 1,
            "max_guests": 3,
            "reserved_host_slots": 2,
            "priority": 100,
            "provisioning_grace_sec": 300,
        },
        {
            "id": "agent",
            "prefix": AGENT_PREFIX,
            "candidate_prefix": AGENT_CAND,
            "desired_idle": 1,
            "max_guests": 1,
            "reserved_host_slots": 0,
            "priority": 50,
            "provisioning_grace_sec": 300,
        },
    ]


def multi_plan(domains, runners_by_pool, github_ok=True, host_max=3):
    ok = {pid: github_ok for pid in ("ci", "agent")}
    if isinstance(github_ok, dict):
        ok = github_ok
    return pool.classify_multi_pool(
        {"host_max_guests": host_max},
        multi_pools(),
        domains,
        runners_by_pool,
        ok,
        now=2000,
    )


class TestPoolSeparation(unittest.TestCase):
    def test_ci_runner_classified_only_by_ci_pool(self):
        p = multi_plan(
            [dom(PREFIX + "a"), dom(AGENT_PREFIX + "b")],
            {
                "ci": [gh(PREFIX + "a", busy=False)],
                "agent": [gh(AGENT_PREFIX + "b", busy=True)],
            },
        )
        self.assertEqual(p["pools"]["ci"]["counts"]["idle"], 1)
        self.assertEqual(p["pools"]["ci"]["counts"]["busy"], 0)
        self.assertEqual(p["pools"]["ci"]["counts"]["total"], 1)
        self.assertNotIn(AGENT_PREFIX + "b", p["pools"]["ci"]["classify"])
        self.assertEqual(p["pools"]["agent"]["counts"]["busy"], 1)
        self.assertNotIn(PREFIX + "a", p["pools"]["agent"]["classify"])

    def test_agent_candidate_excluded_from_agent_reconciliation(self):
        p = multi_plan(
            [dom(AGENT_PREFIX + "a"), dom(AGENT_CAND + "x"), dom("homeassistant")],
            {"ci": [], "agent": [gh(AGENT_PREFIX + "a", busy=False)]},
        )
        self.assertEqual(p["pools"]["agent"]["counts"]["total"], 1)
        self.assertNotIn(AGENT_CAND + "x", p["pools"]["agent"]["classify"])
        self.assertNotIn("homeassistant", p["destroy"])

    def test_ci_candidate_excluded_from_ci_reconciliation(self):
        p = multi_plan(
            [dom(PREFIX + "a"), dom(CAND + "x")],
            {"ci": [gh(PREFIX + "a", busy=False)], "agent": []},
        )
        self.assertEqual(p["pools"]["ci"]["counts"]["total"], 1)
        self.assertNotIn(CAND + "x", p["pools"]["ci"]["classify"])
        self.assertNotIn(CAND + "x", p["destroy"])

    def test_foreign_domains_untouched(self):
        p = multi_plan(
            [dom("homeassistant"), dom("unrelated-vm")],
            {"ci": [], "agent": []},
        )
        self.assertEqual(p["destroy"], [])
        self.assertEqual(p["host_total"], 0)


class TestHostCapacity(unittest.TestCase):
    def test_agent_cannot_exceed_its_cap(self):
        p = multi_plan(
            [dom(AGENT_PREFIX + "a")],
            {"ci": [], "agent": [gh(AGENT_PREFIX + "a", busy=True)]},
        )
        # busy agent, desired idle 1, but max_guests=1 → no more agent provision
        self.assertEqual(p["provision"]["agent"], 0)

    def test_combined_pools_cannot_exceed_host_cap(self):
        # 2 CI busy + 1 agent busy = host full; neither provisions
        p = multi_plan(
            [
                dom(PREFIX + "a"),
                dom(PREFIX + "b"),
                dom(AGENT_PREFIX + "x"),
            ],
            {
                "ci": [gh(PREFIX + "a", busy=True), gh(PREFIX + "b", busy=True)],
                "agent": [gh(AGENT_PREFIX + "x", busy=True)],
            },
        )
        self.assertEqual(p["host_total"], 3)
        self.assertEqual(p["provision"]["ci"], 0)
        self.assertEqual(p["provision"]["agent"], 0)
        self.assertTrue(p["host_saturated"])

    def test_ci_idle_capacity_preserved_with_busy_agent(self):
        # Agent occupies 1 slot; CI reserved=2 → CI can still hold 2 guests.
        # 1 busy CI + 1 busy agent, host has 1 free → CI gets the idle spare.
        p = multi_plan(
            [dom(PREFIX + "a"), dom(AGENT_PREFIX + "x")],
            {
                "ci": [gh(PREFIX + "a", busy=True)],
                "agent": [gh(AGENT_PREFIX + "x", busy=True)],
            },
        )
        self.assertEqual(p["provision"]["ci"], 1)
        self.assertEqual(p["provision"]["agent"], 0)
        self.assertEqual(p["host_total_after_provision"], 3)

    def test_busy_agent_counts_against_host_capacity(self):
        p = multi_plan(
            [
                dom(PREFIX + "a"),
                dom(PREFIX + "b"),
                dom(AGENT_PREFIX + "x"),
            ],
            {
                "ci": [
                    gh(PREFIX + "a", busy=False),
                    gh(PREFIX + "b", busy=True),
                ],
                "agent": [gh(AGENT_PREFIX + "x", busy=True)],
            },
        )
        self.assertEqual(p["host_total"], 3)
        self.assertEqual(p["provision"]["ci"], 0)
        self.assertEqual(p["provision"]["agent"], 0)

    def test_ci_priority_over_agent_when_contending(self):
        # Empty host: both want 1 idle. CI priority wins first; agent also fits.
        p = multi_plan([], {"ci": [], "agent": []})
        self.assertEqual(p["provision"]["ci"], 1)
        self.assertEqual(p["provision"]["agent"], 1)
        self.assertEqual(p["host_total_after_provision"], 2)

    def test_agent_blocked_when_only_ci_reserved_slots_remain(self):
        # 2 CI guests occupy the reserved floor; 1 host slot free but must stay
        # available for CI reservation need? reserved=2, ci_total=2 → need=0,
        # so agent CAN take the remaining 1 slot.
        p = multi_plan(
            [dom(PREFIX + "a"), dom(PREFIX + "b")],
            {
                "ci": [gh(PREFIX + "a", busy=True), gh(PREFIX + "b", busy=True)],
                "agent": [],
            },
        )
        # CI wants idle replacement but host remaining after CI wish:
        # CI uncapped wish=1, host_remaining=1, reserved_for_others=0 → CI takes 1
        # then host full → agent 0. CI starvation protection via priority.
        self.assertEqual(p["provision"]["ci"], 1)
        self.assertEqual(p["provision"]["agent"], 0)

    def test_simultaneous_reconcile_cannot_race_past_host_cap(self):
        # Pure planner is atomic: given snapshot at 2 guests, allocations sum
        # cannot exceed remaining 1 slot; CI priority gets it.
        p = multi_plan(
            [dom(PREFIX + "a"), dom(AGENT_PREFIX + "x")],
            {
                "ci": [gh(PREFIX + "a", busy=True)],
                "agent": [gh(AGENT_PREFIX + "x", busy=True)],
            },
        )
        self.assertEqual(sum(p["provision"].values()), 1)
        self.assertLessEqual(p["host_total_after_provision"], 3)

    def test_provisioning_guests_count_correctly(self):
        p = multi_plan(
            [dom(PREFIX + "boot", created_at=1900)],
            {"ci": [], "agent": []},
        )
        self.assertEqual(p["pools"]["ci"]["counts"]["provisioning"], 1)
        self.assertEqual(p["provision"]["ci"], 0)  # provisioning satisfies idle

    def test_uncertain_fail_closed_no_overprovision(self):
        p = multi_plan(
            [dom(PREFIX + "a"), dom(AGENT_PREFIX + "x")],
            {"ci": [], "agent": []},
            github_ok=False,
        )
        self.assertEqual(p["pools"]["ci"]["counts"]["uncertain"], 1)
        self.assertEqual(p["pools"]["agent"]["counts"]["uncertain"], 1)
        self.assertEqual(p["provision"]["ci"], 0)
        self.assertEqual(p["provision"]["agent"], 0)
        self.assertEqual(p["destroy"], [])

    def test_github_outage_does_not_overprovision(self):
        p = multi_plan([], {"ci": [], "agent": []}, github_ok=False)
        self.assertEqual(p["provision"]["ci"], 0)
        self.assertEqual(p["provision"]["agent"], 0)


class TestAgentLifecyclePlanning(unittest.TestCase):
    def test_agent_stale_destroyed_and_ci_untouched(self):
        p = multi_plan(
            [
                dom(AGENT_PREFIX + "dead", state="shut off"),
                dom(PREFIX + "a"),
            ],
            {"ci": [gh(PREFIX + "a", busy=False)], "agent": []},
        )
        self.assertIn(AGENT_PREFIX + "dead", p["destroy"])
        self.assertNotIn(PREFIX + "a", p["destroy"])
        self.assertEqual(p["pools"]["ci"]["counts"]["idle"], 1)

    def test_ci_cleanup_cannot_delete_agent_state(self):
        # Single-pool classify for CI must ignore agent domains.
        p = pool.classify_domains(
            cfg(),
            [dom(PREFIX + "a"), dom(AGENT_PREFIX + "x", state="shut off")],
            [gh(PREFIX + "a", busy=False)],
            github_ok=True,
            now=2000,
        )
        self.assertNotIn(AGENT_PREFIX + "x", p["destroy"])
        self.assertNotIn(AGENT_PREFIX + "x", p["classify"])

if __name__ == "__main__":
    unittest.main(verbosity=2)
