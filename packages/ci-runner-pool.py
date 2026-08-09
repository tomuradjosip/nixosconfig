#!/usr/bin/env python3
"""Pure, deterministic pool planner for the ephemeral CI runner platform.

This module contains ONLY decision logic: given a snapshot of locally managed
libvirt domains and the authoritative GitHub view of registered runners, it
classifies every managed guest into an explicit pool state and computes how many
fresh idle replacements to provision, subject to a hard maximum.

It performs no I/O of its own (no libvirt, no network). The surrounding bash
`ci-runnerctl` collects the snapshot (libvirt + GitHub API) and executes the
returned plan under a host-side lock. Keeping the arithmetic here — free of side
effects — is what makes the max-guests invariant unit-testable (see
`tests/ci_runner_pool_test.py`).

Authority split (see docs/configuration/ci-runner.md):
  * GitHub is authoritative for whether a registered runner is busy/idle.
  * Local libvirt/provisioner state is authoritative for how many guests exist.
  * Neither side is blindly trusted: a running guest with no online GitHub runner
    is provisioning (within a grace window) or uncertain/stale (past it), and a
    GitHub outage forces fail-closed behaviour (no provisioning, no destroys of
    running guests).

Pool states (Section 8 of the hardening spec):
  provisioning   guest running, GitHub runner not yet online, within grace
  idle           GitHub runner online and busy == false
  busy           GitHub runner online and busy == true
  shutting_down  libvirt reports an in-shutdown transition
  stale          libvirt not running (shut off/crashed) -> destroy
  uncertain      running but unclassifiable; destroyed only when GitHub is
                 reachable and the grace window has elapsed, otherwise retained
"""

import json
import sys

# --- Pool state constants -------------------------------------------------

PROVISIONING = "provisioning"
IDLE = "idle"
BUSY = "busy"
SHUTTING_DOWN = "shutting_down"
STALE = "stale"
UNCERTAIN = "uncertain"

# libvirt domain states that are NOT "running".
_NON_RUNNING = {
    "shut off",
    "shutoff",
    "crashed",
    "paused",
    "pmsuspended",
    "blocked",
    "dying",
    "missing",
    "",
}
_IN_SHUTDOWN = {"in shutdown", "shutdown"}

DEFAULT_PROVISIONING_GRACE_SEC = 300


def compute_to_provision(desired_idle, max_guests, idle, total, github_ok,
                         provisioning=0):
    """Core scaling arithmetic (Section 10).

    Provision enough to satisfy the idle deficit, never exceeding the remaining
    capacity below max_guests. `total` MUST already include every managed guest
    that will continue to exist this pass (provisioning + idle + busy +
    uncertain-retained); stale/shutting-down guests scheduled for destruction in
    the same pass are excluded because their capacity is reclaimed first.

    Guests already in `provisioning` count toward the idle supply: they are
    intended to become online/idle, so creating more while they boot would race
    past desiredIdleCapacity (and potentially maxGuests under concurrent timers).

    A GitHub outage (github_ok False) yields 0: we never provision on an unknown
    pool state, to avoid overcommit.
    """
    if not github_ok:
        return 0
    idle_supply = idle + max(provisioning, 0)
    idle_deficit = max(desired_idle - idle_supply, 0)
    remaining = max(max_guests - total, 0)
    return min(idle_deficit, remaining)


def _normalize_state(state):
    return (state or "").strip().lower()


def classify_domains(config, domains, github_runners, github_ok, now):
    """Classify managed production domains and derive a provisioning plan.

    Only domains whose name starts with config["prefix"] are considered managed
    production guests. Candidate-validation domains (config["candidate_prefix"])
    and any unrelated libvirt domains are ignored entirely — never counted toward
    the pool total and never destroyed. This prefix boundary is a safety
    invariant (Section 3): the production reconciler must never touch candidate or
    foreign VMs.

    Returns a dict:
      github_ok, classify {name: state}, destroy [names],
      counts {idle,busy,provisioning,uncertain,stale,shutting_down,total},
      provision (int), saturated (bool)
    """
    prefix = config["prefix"]
    candidate_prefix = config.get("candidate_prefix", "ci-candidate-")
    desired_idle = config["desired_idle"]
    max_guests = config["max_guests"]
    grace = config.get("provisioning_grace_sec", DEFAULT_PROVISIONING_GRACE_SEC)

    runners_by_name = {r.get("name"): r for r in github_runners}

    classify = {}
    destroy = []
    counts = {
        IDLE: 0,
        BUSY: 0,
        PROVISIONING: 0,
        UNCERTAIN: 0,
        STALE: 0,
        SHUTTING_DOWN: 0,
    }

    for dom in domains:
        name = dom["name"]
        # Prefix boundary: skip candidate + unrelated domains outright.
        if not name.startswith(prefix):
            continue
        # Defence in depth: a candidate-prefixed name must never be a production
        # prefix (they are distinct namespaces), but guard anyway.
        if candidate_prefix and name.startswith(candidate_prefix):
            continue

        state = _normalize_state(dom.get("libvirt_state"))
        runner = runners_by_name.get(name)
        created_at = dom.get("created_at") or 0
        age = now - created_at if created_at else None

        if state in _IN_SHUTDOWN:
            classify[name] = SHUTTING_DOWN
            counts[SHUTTING_DOWN] += 1
            destroy.append(name)
            continue
        if state in _NON_RUNNING:
            classify[name] = STALE
            counts[STALE] += 1
            destroy.append(name)
            continue

        # Running from here on.
        if not github_ok:
            # Cannot classify busy/idle safely -> retain, do not destroy.
            classify[name] = UNCERTAIN
            counts[UNCERTAIN] += 1
            continue

        online = bool(runner) and runner.get("status") == "online"
        if online and not runner.get("busy", False):
            classify[name] = IDLE
            counts[IDLE] += 1
        elif online and runner.get("busy", False):
            classify[name] = BUSY
            counts[BUSY] += 1
        else:
            # Running but no online GitHub runner: booting/registering, or dead.
            if age is None or age <= grace:
                classify[name] = PROVISIONING
                counts[PROVISIONING] += 1
            else:
                # Past grace with no online runner -> contaminated. A genuinely
                # busy runner would still be *online* (only busy may desync), so
                # this never kills working jobs.
                classify[name] = UNCERTAIN
                counts[UNCERTAIN] += 1
                destroy.append(name)

    destroy_set = set(destroy)
    # total = every managed guest that will still exist after this pass.
    total = sum(1 for d in domains
                if d["name"].startswith(prefix)
                and not (candidate_prefix and d["name"].startswith(candidate_prefix))
                and d["name"] not in destroy_set)

    idle = counts[IDLE]
    provisioning = counts[PROVISIONING]
    provision = compute_to_provision(
        desired_idle, max_guests, idle, total, github_ok,
        provisioning=provisioning,
    )
    saturated = github_ok and idle == 0 and total >= max_guests

    counts_out = dict(counts)
    counts_out["total"] = total

    return {
        "github_ok": github_ok,
        "classify": classify,
        "destroy": destroy,
        "counts": counts_out,
        "provision": provision,
        "saturated": saturated,
        "desired_idle": desired_idle,
        "max_guests": max_guests,
    }


def _main(argv):
    """CLI: read a snapshot JSON on stdin, print the plan JSON on stdout.

    Snapshot schema:
      {"config": {...}, "now": <epoch>, "github_ok": bool,
       "domains": [{"name","libvirt_state","created_at"}...],
       "github_runners": [{"name","status","busy"}...]}
    """
    if len(argv) < 2 or argv[1] != "plan":
        sys.stderr.write("usage: ci-runner-pool plan < snapshot.json\n")
        return 2
    snap = json.load(sys.stdin)
    plan = classify_domains(
        snap["config"],
        snap.get("domains", []),
        snap.get("github_runners", []),
        snap.get("github_ok", False),
        snap.get("now", 0),
    )
    json.dump(plan, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
