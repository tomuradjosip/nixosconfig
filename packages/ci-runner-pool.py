#!/usr/bin/env python3
"""Pure, deterministic pool planner for the ephemeral runner platform.

This module contains ONLY decision logic: given a snapshot of locally managed
libvirt domains and the authoritative GitHub view of registered runners, it
classifies every managed guest into an explicit pool state and computes how many
fresh idle replacements to provision, subject to per-pool and host-wide caps.

It performs no I/O of its own (no libvirt, no network). The surrounding bash
`ci-runnerctl` collects the snapshot (libvirt + GitHub API) and executes the
returned plan under a host-side lock. Keeping the arithmetic here — free of side
effects — is what makes the max-guests / host-capacity invariants unit-testable
(see `tests/ci_runner_pool_test.py`).

Authority split (see docs/configuration/ci-runner.md):
  * GitHub is authoritative for whether a registered runner is busy/idle.
  * Local libvirt/provisioner state is authoritative for how many guests exist.
  * Neither side is blindly trusted: a running guest with no online GitHub runner
    is provisioning (within a grace window) or uncertain/stale (past it), and a
    GitHub outage forces fail-closed behaviour (no provisioning, no destroys of
    running guests).

Pool states:
  provisioning   guest running, GitHub runner not yet online, within grace
  idle           GitHub runner online and busy == false
  busy           GitHub runner online and busy == true
  shutting_down  libvirt reports an in-shutdown transition
  stale          libvirt not running (shut off/crashed) -> destroy
  uncertain      running but unclassifiable; destroyed only when GitHub is
                 reachable and the grace window has elapsed, otherwise retained

Multi-pool / host capacity:
  Independent pools (e.g. CI vs agent) share one physical-host guest ceiling.
  Higher-priority pools provision first. `reserved_host_slots` on a pool is a
  floor that lower-priority pools may not consume (CI starvation protection).
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
    """Core per-pool scaling arithmetic.

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
    """Classify managed production domains for a single pool and derive a plan.

    Only domains whose name starts with config["prefix"] are considered managed
    production guests. Candidate-validation domains (config["candidate_prefix"])
    and any unrelated libvirt domains are ignored entirely — never counted toward
    the pool total and never destroyed. This prefix boundary is a safety
    invariant: the production reconciler must never touch candidate or foreign VMs.

    Returns a dict:
      pool_id, github_ok, classify {name: state}, destroy [names],
      counts {idle,busy,provisioning,uncertain,stale,shutting_down,total},
      provision (int), saturated (bool), desired_idle, max_guests
    """
    prefix = config["prefix"]
    candidate_prefix = config.get("candidate_prefix", "ci-candidate-")
    desired_idle = config["desired_idle"]
    max_guests = config["max_guests"]
    grace = config.get("provisioning_grace_sec", DEFAULT_PROVISIONING_GRACE_SEC)
    pool_id = config.get("id", "ci")

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
        "pool_id": pool_id,
        "github_ok": github_ok,
        "classify": classify,
        "destroy": destroy,
        "counts": counts_out,
        "provision": provision,
        "saturated": saturated,
        "desired_idle": desired_idle,
        "max_guests": max_guests,
    }


def _pool_cfg(raw):
    """Normalize a multi-pool config entry."""
    return {
        "id": raw["id"],
        "prefix": raw["prefix"],
        "candidate_prefix": raw.get("candidate_prefix", ""),
        "desired_idle": raw["desired_idle"],
        "max_guests": raw["max_guests"],
        "provisioning_grace_sec": raw.get(
            "provisioning_grace_sec", DEFAULT_PROVISIONING_GRACE_SEC),
        "reserved_host_slots": int(raw.get("reserved_host_slots", 0)),
        "priority": int(raw.get("priority", 0)),
    }


def allocate_host_provisions(host_max, pool_plans, pool_cfgs):
    """Apply host-wide ceiling + reserved slots to per-pool provision wishes.

    `pool_plans` is a list of classify_domains results (post-destroy totals).
    `pool_cfgs` is the matching list of normalized pool configs.

    Returns {pool_id: provision_int} and host summary fields.

    Rules:
      * sum(pool totals after provisioning) <= host_max
      * each pool total <= its max_guests (already in per-pool wish)
      * for any pool P, lower-priority pools may not consume capacity that would
        drop P below its reserved_host_slots occupancy budget:
          other_lower_priority_total <= host_max - P.reserved_host_slots
        Equivalently, when deciding how many slots a pool may take:
          remaining_for_pool = host_max - host_total - reserved_held_by_others
        where reserved_held_by_others is the sum of reserved_host_slots of pools
        with strictly higher priority (those floors must stay free for them).

    Higher priority provisions first so CI can reclaim host capacity before an
    agent idle spare is (re)created.
    """
    by_id = {p["pool_id"]: p for p in pool_plans}
    cfg_by_id = {c["id"]: c for c in pool_cfgs}

    totals = {pid: by_id[pid]["counts"]["total"] for pid in by_id}
    wishes = {pid: int(by_id[pid]["provision"]) for pid in by_id}
    allocated = {pid: 0 for pid in by_id}

    # Stable: higher priority first, then id for determinism.
    order = sorted(
        by_id.keys(),
        key=lambda pid: (-cfg_by_id[pid]["priority"], pid),
    )

    for pid in order:
        wish = wishes[pid]
        if wish <= 0:
            continue
        host_total = sum(totals.values())
        host_remaining = max(host_max - host_total, 0)

        # Slots that must remain available for higher-priority pools' reservations.
        reserved_for_others = 0
        for other_id, cfg in cfg_by_id.items():
            if cfg["priority"] > cfg_by_id[pid]["priority"]:
                # How many more reserved slots does `other` still need beyond its
                # current occupancy?
                need = max(cfg["reserved_host_slots"] - totals[other_id], 0)
                reserved_for_others += need

        available = max(host_remaining - reserved_for_others, 0)
        # Also respect this pool's own max (wish already capped) and any
        # self-reservation interaction via host_max - own reserved for lowers —
        # handled when those lower pools run.
        take = min(wish, available)
        allocated[pid] = take
        totals[pid] += take

    host_total_after = sum(totals.values())
    return {
        "allocations": allocated,
        "host_total": host_total_after,
        "host_max": host_max,
        "host_saturated": host_total_after >= host_max,
    }


def classify_multi_pool(host_config, pools, domains, runners_by_pool, github_ok_by_pool, now):
    """Plan all pools under one shared host ceiling.

    host_config: {host_max_guests: int}
    pools: list of pool config dicts (see _pool_cfg)
    domains: all libvirt domain snapshots
    runners_by_pool: {pool_id: [runner dicts]}
    github_ok_by_pool: {pool_id: bool}

    Returns:
      {
        host_max, host_total, host_saturated,
        pools: {pool_id: classify_domains result with provision overridden},
        destroy: [all names],
        provision: {pool_id: int},
      }
    """
    host_max = int(host_config["host_max_guests"])
    cfgs = [_pool_cfg(p) for p in pools]

    # Prefix collision safety: production prefixes must be pairwise distinct and
    # must not prefix-overlap each other or any candidate prefix.
    prefixes = [(c["id"], c["prefix"], c["candidate_prefix"]) for c in cfgs]
    for i, (id_a, pre_a, cand_a) in enumerate(prefixes):
        for id_b, pre_b, cand_b in prefixes[i + 1:]:
            if pre_a == pre_b:
                raise ValueError(f"duplicate domain prefix between {id_a} and {id_b}")
            if pre_a.startswith(pre_b) or pre_b.startswith(pre_a):
                raise ValueError(
                    f"overlapping domain prefixes {id_a}={pre_a!r} {id_b}={pre_b!r}")
        if cand_a and (pre_a.startswith(cand_a) or cand_a.startswith(pre_a)):
            raise ValueError(
                f"pool {id_a}: domain/candidate prefixes must not prefix-overlap")

    plans = []
    for cfg in cfgs:
        pid = cfg["id"]
        plan = classify_domains(
            cfg,
            domains,
            runners_by_pool.get(pid, []),
            bool(github_ok_by_pool.get(pid, False)),
            now,
        )
        plans.append(plan)

    # Host allocation uses post-destroy totals already in each plan.
    host = allocate_host_provisions(host_max, plans, cfgs)
    allocations = host["allocations"]

    pools_out = {}
    destroy_all = []
    for plan in plans:
        pid = plan["pool_id"]
        uncapped = plan["provision"]
        out = dict(plan)
        out["provision_uncapped"] = uncapped
        out["provision"] = allocations[pid]
        pools_out[pid] = out
        destroy_all.extend(out["destroy"])

    host_total = sum(p["counts"]["total"] for p in pools_out.values())
    host_total_after_prov = host_total + sum(allocations.values())

    return {
        "host_max": host_max,
        "host_total": host_total,
        "host_total_after_provision": host_total_after_prov,
        "host_saturated": host_total_after_prov >= host_max,
        "pools": pools_out,
        "destroy": destroy_all,
        "provision": allocations,
    }


def _main(argv):
    """CLI: read a snapshot JSON on stdin, print the plan JSON on stdout.

    Single-pool snapshot schema (backward compatible):
      {"config": {...}, "now": <epoch>, "github_ok": bool,
       "domains": [{"name","libvirt_state","created_at"}...],
       "github_runners": [{"name","status","busy"}...]}

    Multi-pool snapshot schema:
      {"mode": "multi", "host": {"host_max_guests": N}, "now": ...,
       "pools": [pool configs...],
       "domains": [...],
       "runners_by_pool": {pool_id: [...]},
       "github_ok_by_pool": {pool_id: bool}}
    """
    if len(argv) < 2 or argv[1] != "plan":
        sys.stderr.write("usage: ci-runner-pool plan < snapshot.json\n")
        return 2
    snap = json.load(sys.stdin)
    if snap.get("mode") == "multi":
        plan = classify_multi_pool(
            snap["host"],
            snap["pools"],
            snap.get("domains", []),
            snap.get("runners_by_pool", {}),
            snap.get("github_ok_by_pool", {}),
            snap.get("now", 0),
        )
    else:
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
