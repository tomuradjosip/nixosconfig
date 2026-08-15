# Ephemeral CI runner — validation report

Validation of the disposable GitHub Actions runner platform (see
**[CI runner platform](ci-runner.md)** for architecture). Performed on the live host on
**2026-08-09**. Repository under test: `tomuradjosip/shopforge`.

> **2026-08-09 reconciliation:** the guest was upgraded to supported stable **NixOS 26.05**,
> generic downloaded-binary compatibility (`nix-ld`) was added, runner freshness monitoring
> was implemented, and a real disposable **Node CI** run was validated. See
> **[Reconciliation update](#reconciliation-update-2026-08-09-stable-guest--node-compat)**
> below; the v1 evidence in this section remains valid.

## Result

The platform meets its v1 requirements. A real workflow job ran inside a disposable VM,
the guest was destroyed after exactly one job, and capacity was automatically restored.
Network isolation, boot/teardown reaping, and observability all behave as designed.

## Environment

| Item | Value |
|------|-------|
| Data root | `/data/ci/{base,overlays,seeds,state,logs}` |
| Network | libvirt NAT `ci-net`, bridge `virbr-ci`, `192.168.67.0/24` (active, autostart) |
| Guest OS | **NixOS 26.05 "Yarara"** (from `nixpkgs-guest`); v1 baseline was 25.05 |
| Guest runner | `github-runner` 2.336.0 (pinned from `nixpkgs-unstable`), `--disableupdate` |
| Capacity | desiredClean = 1, maxGuests = 1 |
| Auth | GitHub App (host-only private key at `/persist/etc/secrets/ci-runner/github-app.pem`) |
| Domain prefix | `ci-ephemeral-` (reaper never touches other VMs, e.g. Home Assistant) |

## Requirements verified

### 1. CI jobs never run on the trusted host
Jobs execute only inside `ci-ephemeral-*` libvirt guests. The host runs provisioning,
reaping, and GitHub App auth only. The GitHub App private key is never injected into a
guest (guests receive only a short-lived registration token via the seed ISO).

### 2. Disposable guest boots, isolates, self-destructs (dummy mode)
Guest serial log (`MODE=dummy`) proved connectivity and isolation in one run:

```
public HTTPS ok            # outbound Internet via NAT works
DNS ok
LAN HTTP blocked as expected      # 192.168.10.7 (trusted LAN) denied
LAN ping blocked as expected
host SSH not reachable as expected
dummy workload complete → requesting poweroff → Power down
```

Network policy confirmed: outbound Internet HTTPS + DNS allowed; RFC1918 (LAN/host/other
private) rejected via the `ci-runner-fwd` chain; host services reachable only via DHCP on
`virbr-ci`.

### 3. Ephemeral runner — exactly one job, then destroyed
Live `smoke` job on guest `ci-ephemeral-20260809153012-15443`:

```
13:30:37Z: Listening for Jobs
13:31:36Z: Running job: smoke
13:31:41Z: Job smoke completed with result: Succeeded
√ Removed .credentials
√ Removed .runner          # ephemeral runner auto-deregistered from GitHub
runner exited rc=0         # clean exit
requesting poweroff → reboot: Power down
```

The provisioner then destroyed the overlay/seed/domain and provisioned a fresh spare
(`ci-ephemeral-20260809153212-17699`), which remained idle and stable — confirming the
one-job-then-dispose contract and automatic capacity restoration.

### 4. Boot reaping is fail-closed
`ci-runnerctl reap-boot` destroyed a guest that was actively **running**:

```
reaper(boot): removing domain ci-ephemeral-...-... (state=running)
→ domain destroyed + undefined, overlay + seed removed
```

This is the exact command wired into `ci-runner-reaper.service`, ordered before the
provisioner, so every leftover CI guest is treated as contaminated at boot.

### 5. Periodic reconcile/soft-reap do not disturb healthy guests
- Soft reap (`reap`) leaves `running` guests and only removes shut-off/orphaned resources.
- `reconcile` leaves a running warm spare in place and refuses to provision when GitHub is
  disabled.

### 6. GitHub App preflight
`ci-runnerctl github-check` validates App credentials/permissions and mints (then
discards) an installation token and a registration token **without registering a runner**.
Used to catch a repo-name misconfiguration before enabling registration.

## Live system state at validation

Metrics (`/var/lib/node_exporter_textfile/ci_runner.prom`):

```
ci_runner_clean_capacity 1
ci_runner_guest_active 1
ci_runner_provision_failures_total 0
ci_runner_teardown_failures_total 0
ci_runner_orphan_cleanup_total 31
ci_runner_overlay_bytes 4980736
```

Units:

```
ci-runner-libvirt-network.service  active   enabled
ci-runner-reaper.service           active   enabled   (RemainAfterExit; boot-only)
ci-runner-provisioner.timer        active   enabled   (every 2m)
ci-runner-provisioner.service      inactive enabled   (oneshot, timer-driven)
```

## Issues found and fixed during validation

1. **Guest lifecycle logs invisible on serial.** `/dev/console` binds to the *last*
   `console=` kernel param; `tty0` was last. Reordered so `ttyS0` is last (captured serial).
2. **Runner rejected / self-update crash-loop.** nixpkgs `nixos-25.05` ships runner 2.326.0,
   which GitHub deprecates; the immutable `/nix/store` also breaks in-place auto-update
   (`tar -xzf` failure). Fixed by pinning runner 2.336.0 from `nixpkgs-unstable` for the
   guest image and adding `--disableupdate`.
3. **~2-minute warm-spare churn.** `ci-runner-provisioner.service` had
   `Wants=ci-runner-reaper.service`; the oneshot reaper (`RemainAfterExit=no`) was re-run on
   every reconcile, destroying the healthy spare. Removed from `Wants` (kept in `After`).
4. **Failed unit on `nixos-rebuild switch`.** A oneshot wanted by `multi-user.target` is
   restarted on every switch, so `reap-boot` re-ran (and raced the lock → `TEMPFAIL`).
   Fixed with `RemainAfterExit=true` on the reaper (runs once per real boot; switches skip
   it) and a blocking lock (`flock -w 120`).

## Known limitations (by design or deferred)

- **maxGuests = 1:** during a running job there is no additional warm spare until the job
  completes and a fresh guest is provisioned.
- **Runner updates are image-managed** (intentional; see reconciliation below): bump
  `nixpkgs-unstable`, rebuild the guest image, `install-base`, recycle. GitHub in-runner
  auto-update is intentionally disabled (`--disableupdate`); freshness is now **monitored**.
- **Docker Engine is not in the guest.** Rootful Podman is guest-local (see platform docs);
  no host Docker/Podman socket is exposed.
- **Real boot-time reap trigger** is validated by command/logic and unit wiring; the exact
  systemd firing on a physical reboot was not exercised (host was not rebooted).
- **Monitoring visibility of workflow runs** requires the GitHub App to also have
  **Actions: Read**; only **Administration** is required for runner registration itself.
- **Host OS is still `nixos-25.05`** (end-of-support). Only the disposable guest was moved to
  26.05; upgrading the host is a separate, larger change out of scope here.

## Reconciliation update (2026-08-09): stable guest + Node compat

Reconciled the platform after the initial validation. Architecture unchanged; findings below.

### Supported stable NixOS guest
- Current supported stable verified from official sources: **26.05 "Yarara"** (released
  2026-05-30, supported through 2026-12-31); 25.05 was end-of-support 2025-12-31.
- Guest moved to 26.05 via a dedicated `nixpkgs-guest` flake input (host stays on `nixpkgs`;
  runner stays on `nixpkgs-unstable`). Candidate image built and booted; serial confirmed
  `Welcome to NixOS 26.05 (Yarara)`.

### Runner update model (formalized)
- `--disableupdate` is **intentional**: the runner lives in the immutable `/nix/store` and
  cannot self-update; Nix/the image is the update authority.
- GitHub requirement confirmed from official docs: registration minimum **2.329.0**; must
  update within **30 days** of a new release or jobs stop queuing; critical security updates
  can pause queuing immediately. Baked runner **2.336.0** == latest release 2.336.0.

### Runner freshness monitoring
- `ci-runner-freshness.timer` (12h) → `ci-runnerctl freshness` compares baked vs latest via
  the public releases API (no credentials) and writes `ci_runner_freshness.prom`. Live run:
  `baked 2.336.0 / latest 2.336.0 / update_available 0 / check_success 1`. Observe-only —
  never edits `flake.lock`.

### Generic Node compatibility — real disposable GitHub Actions run
Run on a dedicated private repo
[`tomuradjosip/nixos-ci-runner-validation`](https://github.com/tomuradjosip/nixos-ci-runner-validation)
(shopforge was **not** used or modified), served by an ephemeral runner booted from the 26.05
candidate image (job `nixos-node-validation`, result **Succeeded**). This repo is
**intentionally retained** as a reusable Node-compatibility regression harness — see
[Validating a candidate image](ci-runner.md#validating-a-candidate-image-regression-harness)
for how to re-run it against a future candidate:

```
Set up job            # actions/checkout extracted with tar (see fix below)
Setup Node 24         # setup-node acquired node-24.19.0-linux-x64.tar.gz
  node --version  ->  v24.19.0        # downloaded ordinary Linux binary runs via nix-ld
  npm  --version  ->  11.17.0
/lib64/ld-linux-x86-64.so.2 -> /nix/store/…-nix-ld-2.0.6/libexec/nix-ld
NIX_LD=/run/current-system/sw/share/nix-ld/lib/ld.so
node -e …          ->  hello from Node v24.19.0 sum= 42
npm install        ->  esbuild@0.24.2 (prebuilt native, postinstall ran)
npx esbuild --version -> 0.24.2       # prebuilt native ELF executes via nix-ld
npm run build      ->  esbuild bundled+minified dist/out.js
corepack pnpm@9.15.0 -> pnpm --version 9.15.0; pnpm dlx cowsay ran  # repo-authoritative PM
Job node completed with result: Succeeded
√ Removed .credentials / .runner  ->  runner exited rc=0  ->  Power down
```

- **`nix-ld` was required.** Downloaded Node and prebuilt native binaries (esbuild) are
  dynamically linked and expect `/lib64/ld-linux-x86-64.so.2`, absent on NixOS. `nix-ld`
  supplies it; the runner service exports `NIX_LD`/`NIX_LD_LIBRARY_PATH` to job steps.
- **One generic PATH fix** during validation: the runner extracts actions with `tar`, which
  was not on the runner service PATH on 26.05 (`tar: command not found`). Added the standard
  archive/text utilities (`tar`, `gzip`, `xz`, `unzip`, `grep`, `sed`, `awk`, `find`) to the
  runner service PATH. This is a small generic fix, **not** a systemic incompatibility.
- Representative native/prebuilt tool tested: **esbuild 0.24.2** (ships a prebuilt native
  executable). Ran correctly. No additional runtime libraries beyond the nix-ld default set
  were needed.

### Candidate isolation + ephemerality (26.05 image)
Dummy-mode candidate serial: `public HTTPS ok`, `DNS ok`, `LAN HTTP blocked`, `LAN ping
blocked`, `host SSH not reachable`, `dummy workload complete` → `Power down`. The runner-mode
candidate processed exactly one job, deregistered, powered off, and its overlay/seed/domain
were destroyed. Candidate guests were booted under non-`ci-ephemeral-*` names so the live
platform reaper/reconciler were never disturbed.

### Deployment
Candidate `install-base`'d as current, idle spare recycled. New spare boots **26.05**, runner
**2.336.0**, registered and `Listening for Jobs`; shopforge shows **1** online runner (stale
offline pruned); `ci_runner_clean_capacity 1`, `ci_runner_guest_active 1`, 0 provision/teardown
failures, single overlay, no leftover writable overlays. Home Assistant and other libvirt
domains untouched.

### Ubuntu?
No evidence justifying a switch to Ubuntu. Standard Node/GitHub-Actions tooling works on the
disposable NixOS guest with a small generic compatibility layer (nix-ld + standard PATH
tools). NixOS remains the preferred guest; Ubuntu stays a documented fallback only.

## Failure policy

`uncertain guest == contaminated guest == destroy`. Overlays are never reset and reused;
each job gets a fresh copy-on-write overlay over the immutable base image.

## Pool hardening + first-class candidate validation (2026-08-09)

Hardening pass after the reconciliation update above. Architecture docs:
**[CI runner platform — idle pool model](ci-runner.md#idle-pool-model)**. Deployed and
exercised on the live host on **2026-08-09**.

### Resource assessment (live host, 2026-08-09)

| Fact | Value |
|------|-------|
| CPU | Intel i3-14100 (8 threads) |
| RAM | 62 GiB; ~20 GiB MemAvailable at measurement; swap 2 GiB full |
| Other VMs | Home Assistant 4 GiB / 2 vCPU |
| CI guest sizing | 4 GiB / 2 vCPU |
| Other load | Dense Podman homelab |
| Theoretical ceiling | `maxGuests=10` → 10 × 4 GiB = 40 GiB guest RAM — **not safe** at current sizing |
| Evidence-based live cap | `services.ciRunner.maxGuests = 3` |
| Idle target | `services.ciRunner.desiredIdleCapacity = 1` |
| Poll interval | `ci-runner-provisioner.timer` every **30s** (was 2m) |

Do not raise `maxGuests` toward the architectural ceiling of 10 without re-checking
MemAvailable / vCPU headroom (prefer right-sizing guest RAM first).

### Unit tests (deterministic planner + network render)

| Item | Result |
|------|--------|
| Module | `packages/ci-runner-pool.py` |
| Tests | `tests/ci_runner_pool_test.py` |
| Count | **31** tests (includes live `maxGuests=3` ceiling cases) |
| Run | `python3 tests/ci_runner_pool_test.py` → all OK |
| Network lib | `packages/ci-runner-network-lib.nix` |
| Network tests | `tests/ci_runner_network_test.py` → **8** OK (DNS hosts, INPUT vs FORWARD, empty allowlists) |

Coverage includes: idle deficit / `maxGuests` arithmetic, provisioning counts toward idle
supply, fail-closed GitHub outage (retain running, no provision), stale/shutting_down
destroy, saturated pool, and `ci-candidate-*` / foreign domain exclusion from the production
pool.

### `validate-candidate` (first-class CLI)

Command (see [platform docs](ci-runner.md#validating-a-candidate-image)):

```bash
sudo ci-runnerctl validate-candidate <qcow2> [--timeout N] [--github-repo OWNER/REPO] [--probe-url URL]
```

| Check | Expected / evidence |
|-------|---------------------|
| Default dummy isolation | PASS markers: public HTTPS, DNS, LAN HTTP/ping blocked, host SSH unreachable, host :80 / AdGuard :3000 unreachable, dummy workload complete; serial retained; production domain set unchanged |
| `--probe-url` / `validationUrls` | Optional internal HTTPS with normal TLS; marker `internal HTTPS ok <url>` |
| Namespace | Guest name `ci-candidate-*`; production reaper/reconciler ignore it |
| No production mutation | Does not call `install-base` / rewrite `current.qcow2` / destroy idle spare |
| `--github-repo` auth | `gh api` registration token or `CI_RUNNER_REG_TOKEN` — **not** the production GitHub App |
| Regression harness | [`tomuradjosip/nixos-ci-runner-validation`](https://github.com/tomuradjosip/nixos-ci-runner-validation) via `validate-candidate --github-repo …` + `gh workflow run node-validation.yml` |

**Live evidence:**

```
# dummy (current base qcow2):
PASS: candidate dummy validation
production domains before/after: ci-ephemeral-20260809175555-18579 (unchanged)
production spare undisturbed: yes
candidate serial retained: /data/ci/logs/ci-candidate-20260809175639-4630.serial.log
no leftover ci-candidate-* domains/overlays/seeds

# GitHub harness (nixos-ci-runner-validation; CI_RUNNER_REG_TOKEN via user gh — not the App):
PASS: candidate GitHub validation (runner exited 0)
Job node completed with result: Succeeded
production spare undisturbed: ci-ephemeral-20260809180325-12126
candidate serial: /data/ci/logs/ci-candidate-20260809180358-13205.serial.log
```

### Pool scale / drain (synthetic, pre-E2E)

Before the real-job elastic-pool run below, forced-provision / fail-closed checks were
recorded (still valid):

| Scenario | Result |
|----------|--------|
| Forced multi-guest up to cap | `ci-runnerctl provision` ×2 → `total=3`; fourth attempt logs `max guests reached` |
| Concurrent reconcile | Two simultaneous `reconcile` under `flock` → both exit 0 |
| GitHub API failure | Pem temporarily moved → `fail-closed`, `github_ok=false`, `provision=0` |
| Busy→provision arithmetic | Synthetic GitHub `busy=true` → `provision=1` via `ci-runner-pool plan` |
| Candidate exclusion | `ci-candidate-*` never counted in production pool during validate-candidate |

## Elastic pool end-to-end validation

**Date/time:** 2026-08-09 ~16:42–16:48 UTC (host CEST 18:42–18:48)  
**Validation repository:** [`tomuradjosip/nixos-ci-runner-validation`](https://github.com/tomuradjosip/nixos-ci-runner-validation)  
**Workflow / run:** `pool-concurrency.yml` / [run 31324469650](https://github.com/tomuradjosip/nixos-ci-runner-validation/actions/runs/31324469650)  
**Harness commit:** `a403109` (after fixing a missing `hostname(1)` abort under `set -e`)  
**Live config during test:** `desiredIdleCapacity=1`, `maxGuests=3`, temporary
`secrets.ciRunner.githubRepo = "nixos-ci-runner-validation"` (consuming app repo not used).  
**Base ID:** `75978281162b0394` (`ci-runner-base-20260809170658.qcow2`)

The GitHub App installation remains shopforge-only (UI/API cannot expand it from this host).
For the harness window the provisioner used **App-first, `gh`/`runuser` fallback** for
runner list + registration-token so systemd reconcile could observe the validation repo.

### State A — initial steady

```
busy=0 idle=1 total=1 saturated=false github_ok=true
runner/domain: ci-ephemeral-20260809184124-32315
overlay: /data/ci/overlays/ci-ephemeral-20260809184124-32315.qcow2
```

Metrics: `ci_runner_idle=1 busy=0 total=1 max_guests=3 desired_idle=1 saturated=0 github_ok=1`.

### First busy → replacement (toward B)

| Time (CEST) | Observation |
|-------------|-------------|
| 18:42:14 | Job `pool (2)` assigned to `…84124-32315` |
| 18:42:33 | `busy=1 idle=0 total=2 provisioning=1` — idle deficit observed; fresh guest `…84226-31818` booting |
| 18:42:56 | Job `pool (3)` on `…84226-31818`; third guest `…84256-3944` provisioning |

Exact `busy=1 idle=1 total=2` was transient (second job claimed the new idle immediately);
the deficit→provision transition is proven by `total=2 provisioning=1` with distinct overlays.

### State C — two busy + one idle

```
18:43:21  busy=2 idle=1 total=3
  ci-ephemeral-20260809184124-32315  busy
  ci-ephemeral-20260809184226-31818  busy
  ci-ephemeral-20260809184256-3944   idle
```

Three domains, three overlays; no fourth guest.

### State D — saturation (critical)

```
18:43:36  busy=3 idle=0 total=3 saturated=true
pool.json: provision=0 saturated=true total=3
```

Job `pool (1)` on `…84256-3944`. After **+35s** further reconcile: still
`busy=3 idle=0 total=3 saturated=1`, **exactly 3** `ci-ephemeral-*` domains/overlays,
`provision=0`. **No fourth runner/guest created.**

Metrics at D / D+35s: `idle=0 busy=3 total=3 max_guests=3 saturated=1 github_ok=1`.

### Concurrent job identities + isolation

| Job | Runner / domain | Overlay | Isolation |
|-----|-----------------|---------|-----------|
| pool (2) | `ci-ephemeral-20260809184124-32315` | own COW | `other_slot_markers=0` → `POOL_JOB_ISOLATION_OK` |
| pool (3) | `ci-ephemeral-20260809184226-31818` | own COW | `other_slot_markers=0` → `POOL_JOB_ISOLATION_OK` |
| pool (1) | `ci-ephemeral-20260809184256-3944` | own COW | `other_slot_markers=0` → `POOL_JOB_ISOLATION_OK` |

All three jobs succeeded (~180s sleep each). No guest was reused for a second job.

### Completion / destruction (each busy guest)

Serial logs (retained under `/data/ci/logs/`) for all three:

```
Running job: pool (…)
Job pool (…) completed with result: Succeeded
√ Removed .credentials
√ Removed .runner
runner exited rc=0
requesting poweroff → reboot: Power down
```

Then provisioner/reaper removed domain + seed + overlay. Completed guests did **not**
return as idle spares.

### State E — drain

```
18:48:35  busy=0 idle=1 total=1 saturated=false
fresh warm spare: ci-ephemeral-20260809184809-305  (not one of the three job guests)
overlay/seed: only that spare remains
GitHub runners: only that spare online
```

Metrics: `idle=1 busy=0 total=1 saturated=0 github_ok=1`.  
`max_total_seen=3`, `fourth_guest_seen=false` over the full timeline.

### Candidate-validation regression (same session)

```
sudo ci-runnerctl validate-candidate /data/ci/base/current.qcow2
→ PASS: candidate dummy validation
production spare undisturbed: ci-ephemeral-20260809184809-305
candidate: ci-candidate-20260809184913-9719 (cleaned; serial retained)
```

### Unit tests

`python3 tests/ci_runner_pool_test.py` → **31** tests OK (includes live `maxGuests=3`
ceiling cases: 0/1/2/3 busy transitions and saturation).

### Bugs found and fixed during this acceptance pass

1. **Harness job abort:** `hostname(1)` missing on guest PATH under `set -e` → fixed in
   `pool-concurrency.yml` (`a403109`); use `RUNNER_NAME` / `/etc/hostname`.
2. **Systemd GitHub harness access:** App cannot see the validation repo; interactive
   `sudo -u … gh` failed under the provisioner unit (no `sudo` on PATH) →
   App-first + `runuser`/`gh` fallback for list/register/stale-delete.
3. **Rebuild destroyed warm spare:** package path change restarted
   `ci-runner-reaper.service` and re-ran `reap-boot` → set
   `restartIfChanged = false` / `stopIfChanged = false` on that unit.

### Final live health (end of E2E, before restoring consuming-app repo target)

```
capacity:
  desired idle: 1
  maximum:      3
  total:        1
  idle:         1
  busy:         0
  provisioning: 0
  saturated:    false
  github_ok:    true
guest: ci-ephemeral-20260809184809-305
```

### Out of scope (unchanged / explicit)

- No workflow_job webhooks, ARC, Kubernetes, or queue-depth scaling
- Gradual burst ramp-up only (30s poll)
- Host NixOS version remains out of scope for this acceptance (`nixos-25.05`)
- Live `maxGuests=10` at 4 GiB/guest is **not** safe on this host
- GitHub App installation was **not** expanded to the harness (fallback used instead)

## Internal Verdaccio HTTPS allowlist (2026-08-09)

**Date/time:** 2026-08-09 ~19:12–19:25 CEST  
**Goal:** make `https://verdaccio.iktstudio.com/` reachable from disposable CI guests with
normal TLS verification, without broad LAN or internal DNS access.

> Note: an earlier pass briefly configured `homepage.iktstudio.com` on the same Traefik IP;
> the intended approved dependency is Verdaccio. Homepage was replaced (not kept alongside).

### Topology (discovered, not assumed)

| Fact | Value |
|------|-------|
| Hostname | `verdaccio.iktstudio.com` |
| Resolved address | **`192.168.10.7`** (this host’s `br0`) |
| Public DNS (`1.1.1.1` / `8.8.8.8`) | NXDOMAIN |
| LAN DNS path on host | router `192.168.10.1` |
| Service | Traefik (Podman rootlessport) listening on host `:443` → Verdaccio |
| Packet path from CI | **INPUT** (`ci-runner-in`), not FORWARD |
| Required port | TCP **443** only |

### Configuration applied

```nix
services.ciRunner = {
  internalDnsHosts = [
    { name = "verdaccio.iktstudio.com"; address = "192.168.10.7"; }
  ];
  hostAllowTcp = [
    { address = "192.168.10.7"; port = 443; }
  ];
  validationUrls = [ "https://verdaccio.iktstudio.com/" ];
};
```

- libvirt `ci-net` dnsmasq: static host + public forwarders `1.1.1.1` / `8.8.8.8`
- Guest resolver: DHCP → `192.168.67.1` (no hardcoded public DNS bypass)
- `internalAllowTcp` left empty (FORWARD path not used for this dependency)

### Positive validation (disposable candidate)

```bash
sudo ci-runnerctl validate-candidate /data/ci/base/current.qcow2 \
  --probe-url https://verdaccio.iktstudio.com/
→ PASS: candidate dummy validation
production spare undisturbed: ci-ephemeral-20260809191903-31234
candidate serial: /data/ci/logs/ci-candidate-20260809192337-25834.serial.log
```

Guest serial evidence (Verdaccio probe):

```
public HTTPS ok
DNS ok
internal HTTPS ok https://verdaccio.iktstudio.com/
verdaccio.iktstudio.com has address 192.168.10.7
LAN HTTP blocked as expected
LAN ping blocked as expected
host SSH not reachable as expected
host HTTP port 80 not reachable as expected
AdGuard UI not reachable as expected
dummy workload complete
```

### Negative isolation (guest serial + CI-subnet netns)

| Probe | Result |
|-------|--------|
| `https://verdaccio.iktstudio.com/` (TLS verify) | **allowed** (HTTP 200) |
| Public HTTPS / public DNS | **allowed** |
| Unmapped `grafana.iktstudio.com` / `homepage.iktstudio.com` via CI DNS | **NXDOMAIN** (not leaked from LAN DNS) |
| Other LAN IP `192.168.10.1:80` | **denied** |
| Approved IP `:22` (SSH) | **denied** |
| Approved IP `:80` | **denied** |
| AdGuard UI `:3000` | **denied** |
| AdGuard DNS `192.168.10.7:53` | **denied** |

### Shared Traefik limitation

`hostAllowTcp` permits TCP to `192.168.10.7:443`. Any other TLS virtual host on that same
Traefik listener is reachable at L4 if the guest knows the name/SNI. Accepted for the
current trust model; hostname ACLs would need an application-layer proxy.

### Final live pool

```
busy=0 idle=1 total=1 maxGuests=3 saturated=false github_ok=true
guest: ci-ephemeral-20260809192407-309  BASE_ID=7e3b6427bda13602
```

**Verdict:** `https://verdaccio.iktstudio.com/` is an approved and validated internal
dependency reachable from disposable CI runners without weakening general LAN isolation.

## Guest Podman + Playwright platform extension (TASK-013 prep)

**Date:** 2026-08-09  
**Branch/commit (historical):** `runner-upgrade` @ `0889c5d` (“runner upgrade”) — committed on
the branch; **not** deployed to production `current.qcow2`.

> **Superseded for acceptance:** the live candidate evidence in this section used an image
> **without** the final `procps` PATH addition and with Playwright **1.55.0**. It remains
> useful historical evidence. The previous correction pass (now committed as `418a457`) is
> recorded in
> **[Final correction pass (2026-08-10)](#final-correction-pass-2026-08-10--historical-now-committed)**.
> Current cleanup acceptance (validated while uncommitted, later committed as `3fbd854`) is in
> **[Final cleanup pass (2026-08-10)](#final-cleanup-pass-2026-08-10--historical-now-committed)**.

Extends the **disposable guest only** so Shopforge browser E2E can run:

```text
Playwright Chromium → Node storefronts → Medusa → PostgreSQL + Redis (Podman Compose)
```

all inside one throwaway GitHub Actions guest. Trusted-host attack surface unchanged
(no host container socket, no libvirt socket to guest, no App key in guest, RFC1918 deny
+ Verdaccio exception unchanged). Guest RAM/vCPU/`maxGuests` **not** changed (still
4096 MiB / 2 vCPU / `maxGuests=3` / `desiredIdleCapacity=1`).

### Declarative changes

| Item | Value |
|------|-------|
| Podman | Enabled rootful in guest; Docker Engine forced off |
| Docker compat / socket alias | Explicitly `false` / disabled |
| Compose provider | `podman-compose` **1.6.0** from existing `nixpkgs-unstable` pin (`containers.conf` + `PODMAN_COMPOSE_PROVIDER`) |
| Why unstable Compose | Guest stable only has 1.5.0 (no `up --wait`) |
| Playwright | Consuming repo owns `@playwright/test` + Chromium revision; guest owns nix-ld Chromium libs + fonts |
| Install model | `playwright install chromium` (not `--with-deps`) |
| Sandbox | Option A: root runner may yield unsandboxed Chromium; no extra `--no-sandbox` flags added |
| Fixtures | `fixtures/ci-runner-e2e/` |
| Deterministic test | `tests/ci_runner_guest_test.py` |
| `procps` | On runner PATH (`free`/`ps`) — present in `0889c5d`, validated in the 2026-08-10 final pass |

### Historical live evidence (2026-08-09; pre-procps / Playwright 1.55.0)

| Check | Status / evidence |
|-------|-------------------|
| Deterministic pool/network/guest tests | **PASS** — `ci_runner_pool_test.py` 31 OK; `ci_runner_network_test.py` 8 OK; `ci_runner_guest_test.py` 11 OK |
| Candidate image build | **PASS** — `nix build .#ci-runner-guest-image` → `result/ci-runner-base.qcow2` |
| Candidate isolation + Verdaccio probe | **PASS** — `ci-candidate-20260809235420-6028`; public HTTPS/DNS ok; Verdaccio HTTPS+TLS ok; LAN/SSH/:80/:3000 blocked; production spare undisturbed |
| Node/pnpm harness regression | **PASS** — [run 31338091805](https://github.com/tomuradjosip/nixos-ci-runner-validation/actions/runs/31338091805) on candidate; setup-node 24 / npm / corepack pnpm / esbuild via nix-ld |
| Podman postgres/redis smoke | **PASS** — `podman info`; `podman-compose` 1.6.0; `up -d --wait`; loopback pg_isready + redis PING; `down -v` (containers only; named-volume proof added later) |
| Playwright Chromium smoke | **PASS** — `@playwright/test@1.55.0`; `playwright install chromium` (no `--with-deps`); headless assertion `ci-runner-playwright-ok`; `DEBUG=pw:browser` |
| Combined workload + cleanup | **PASS** — [run 31338724089](https://github.com/tomuradjosip/nixos-ci-runner-validation/actions/runs/31338724089) (~1m30s); candidate powered off; overlay/seed destroyed; production `ci-ephemeral-20260809222011-6654` undisturbed |
| Fresh-guest isolation of Podman state | **PASS by construction** — writable overlay destroyed; next guest has empty container storage |

### Historical resource measurements (combined job, 4 GiB / 2 vCPU guest)

| Metric | Value |
|--------|-------|
| Root FS before smokes | 12G total, **3.7G used**, 7.4G avail (33%) |
| Root FS after smokes | 12G total, **5.1G used**, 6.0G avail (46%) |
| Playwright browser cache | **919M** (`~/.cache/ms-playwright`) |
| Podman images after down | 2 images, **336.9MB** (reclaimable; containers 0) |
| vCPU observed | `nproc` → **2** |
| `free` | **not** on job PATH in that image build (`procps` was added afterward in `0889c5d`) |
| Guest RAM/vCPU/`maxGuests` | **unchanged** — 4096 MiB / 2 / 3; no OOM observed on this fixture |

Chromium launched under root with Playwright’s default `--no-sandbox` (Option A; not added by the runner image).

First fixture attempt failed only because the smoke script called `python3` (absent by design); fixed to `podman exec` + Node.

## Final correction pass (2026-08-10) — historical (now committed)

**Purpose:** close validation gaps before any production `install-base`: current stable
Playwright pin, named-volume `down -v` proof, EXIT cleanup traps, `procps`/resource
measurements (including peak memory when available), and a **fresh** candidate built from
the exact corrected working tree.

**Repository state at start of that pass:** branch `runner-upgrade` @ `0889c5d` (clean).
**How it was developed:** corrections were initially developed and validated **uncommitted**,
then committed and pushed on `runner-upgrade` as `418a457` (“runner upgrade improvements”).
**Not** merged to `main`. **No** `install-base` / `recycle-idle` (production base unchanged).

> **Superseded for acceptance of the EXIT/`up --wait` cleanup edge case:** that pass’s
> EXIT traps still gated teardown on `COMPOSE_STARTED=1`, which can miss partial
> `up -d --wait` failures. Final acceptance for that fix (validated from the dirty working
> tree, later committed as `3fbd854`) is recorded in
> **[Final cleanup pass (2026-08-10)](#final-cleanup-pass-2026-08-10--historical-now-committed)**.

### Corrections applied (committed in `418a457`)

| Area | Change |
|------|--------|
| Playwright | Default `PLAYWRIGHT_VERSION=1.62.1` (npm registry `@playwright/test` latest as of 2026-08-10); overridable; still `playwright install chromium` without `--with-deps` |
| Podman volumes | Explicit project-local named volumes `pgdata` + `redisdata`; smoke asserts they exist after `up` and are **gone** after `down -v` |
| Cleanup traps | `podman-smoke.sh` / `combined-smoke.sh` EXIT traps tear down Compose if a mid-run assertion fails without masking the original failure; success path still runs the explicit volume-removal proof (see later pass for `up --wait` partial-failure gap) |
| Tests | Guest tests assert `procps` on runner PATH + fixture contracts (Playwright pin, volume proof, traps) |
| nix-ld libs | Unchanged unless a newer Chromium launch failure forces a narrow addition (recorded below) |

### Historical candidate validation evidence (working tree → later `418a457`)

| Check | Status / evidence |
|-------|-------------------|
| Deterministic pool/network/guest tests | **PASS** — pool 31 OK; network 8 OK; guest **17** OK (includes `procps` PATH + fixture contracts) |
| Fresh image build (includes `procps`) | **PASS** — `nix build .#ci-runner-guest-image` → `/nix/store/pnwqd0gd8bhv859ks03pfy8c7d3h1219-ci-runner-guest-image` (`result/ci-runner-base.qcow2`, ~1.2G) |
| Isolation + Verdaccio candidate | **PASS** — `ci-candidate-20260810002818-9717`; serial retained; public HTTPS/DNS ok; Verdaccio HTTPS+TLS + resolve `192.168.10.7`; LAN/SSH/:80/:3000 blocked; production spare undisturbed |
| Node regression harness | **PASS** — [run 31339530300](https://github.com/tomuradjosip/nixos-ci-runner-validation/actions/runs/31339530300); candidate `ci-candidate-20260810002909-26252`; setup-node 24 / npm / corepack pnpm / esbuild; runner exited 0 → Power down |
| Combined E2E (`e2e-platform-smoke.yml`) | **PASS** — [run 31339593508](https://github.com/tomuradjosip/nixos-ci-runner-validation/actions/runs/31339593508) on harness branch `final-correction-20260810` (~1m30s); candidate `ci-candidate-20260810003034-32516` |
| Playwright version | **`@playwright/test@1.62.1`** (npm registry latest as of 2026-08-10); Chromium **151.0.7922.34** / revision **chromium-1234** / headless-shell-1234; `DEBUG=pw:browser` launch ok; assertion `ci-runner-playwright-ok` |
| Named volume removal proof | **PASS** — after `up`: `ci-runner-e2e_pgdata` + `ci-runner-e2e_redisdata` present; after `down -v`: project containers gone, named volumes gone (`Local Volumes 0`), images may remain cached (2×336.9MB) |
| nix-ld Chromium libs | **No addition required** for 1.62.1 / Chromium 151 — existing library set sufficient |
| Resource / peak memory / `free` via `procps` | **PASS** — see table below; `free -m` available on PATH |
| Production base | **unchanged** — still `ci-runner-base-20260809191858.qcow2` (`BASE_ID=7e3b6427bda13602`); spare `ci-ephemeral-20260809222011-6654` undisturbed across all three candidates; **not** deployed |

### Historical resource measurements (combined job, 4 GiB / 2 vCPU guest)

| Metric | Value |
|--------|-------|
| Baseline `free -m` | total **3918** MiB; used **578**; available **3340** |
| After browser `free -m` | used **833**; available **3085** |
| After teardown `free -m` | used **716**; available **3201** |
| `memory.peak` (job cgroup) | baseline **1014652928** (~968 MiB) → after **2552938496** (~2435 MiB / **~2.38 GiB**) |
| `memory.peak` (`system.slice`) | baseline **1131048960** → after browser/teardown **2669285376** (~2545 MiB / **~2.48 GiB**) |
| Root FS | before **3.7G/12G (33%)**; after **4.7G/12G (42–43%)** |
| Playwright cache | **656M** (`~/.cache/ms-playwright`) |
| Podman after `down -v` | Images **2 / 336.9MB** reclaimable; Containers **0**; Local Volumes **0** |
| vCPU | `nproc` → **2** |
| OOM | **none** observed |
| Guest RAM/vCPU/`maxGuests` | **unchanged** — 4096 MiB / 2 / 3 |

Chromium launched under root with Playwright’s default `--no-sandbox` (Option A; not added by the runner image). Headless launch succeeded without extra nix-ld packages.

### Production deployment (that pass)

**Forbidden — confirmed not performed.** Production idle spare remained on the
pre-extension base (`BASE_ID=7e3b6427bda13602`). Corrections were later committed as
`418a457` on `runner-upgrade` (still **not** merged to `main`, still **not** installed).

Harness note: fixtures were synced for that run onto temporary branch
`final-correction-20260810` in `tomuradjosip/nixos-ci-runner-validation` (commit `94b1b1f`);
not merged to harness `main`.

## Final cleanup pass (2026-08-10) — historical (now committed)

**Purpose:** close the remaining Compose failure-path cleanup gap and re-validate the full
guest platform from the exact final working tree before any production deployment.

**Bug:** EXIT traps gated project `down -v` on `COMPOSE_STARTED=1`, set only **after**
`podman compose up -d --wait` returned success. A partial `up` that then failed (e.g. health
timeout) exited under `set -e` before the flag was set, so the trap skipped cleanup and
left project containers/named volumes behind.

**Repository state at start of this pass:** branch `runner-upgrade` @ `418a457` (clean,
pushed; tip of previous correction pass). Historical starting commit remains `0889c5d`.
**Not** merged to `main`. Production still on `BASE_ID=7e3b6427bda13602`.

**Working-tree state during validation:** failure-path cleanup fix + docs + fixture tests
were developed and fully validated **while uncommitted** on top of `418a457`. During that
validation cycle there was **no** nixosconfig commit/push and **no** `install-base` /
`recycle-idle`.

**Current repository state (after validation):** those cleanup corrections were subsequently
committed and pushed to `runner-upgrade` as `3fbd854` (“runner upgrade improvements v2”).
They remain **unmerged** to `main` and were **not** installed as the production runner base
during this validation cycle.

### Fixes applied (later committed as `3fbd854`)

| Area | Change |
|------|--------|
| Cleanup model | `podman-smoke.sh` / `combined-smoke.sh` EXIT traps unconditionally attempt project-scoped `down -v` while `VOLUME_PROOF_DONE=0` (no `COMPOSE_STARTED` gate); cleanup errors ignored so they never mask the original failure; success path still runs explicit `down -v` + removal assertions then sets `VOLUME_PROOF_DONE=1` (trap skips — no duplicate teardown) |
| Failure-path fixture | `fixtures/ci-runner-e2e/podman-failure-cleanup-smoke.sh` — intentional fail-after-up (exit 42) and controlled `up -d --wait` health failure; proves EXIT cleanup removes project containers + named volumes; no global prune; temp broken compose not left in the tree |
| Tests | Guest fixture contracts assert the new trap model + failure-path script shape |
| Docs | Distinguish historical `0889c5d`, committed `418a457`, and this cleanup pass (validated dirty, later `3fbd854`); clarify nothing merged/installed |

### Final-candidate validation evidence (working tree → later `3fbd854`)

| Check | Status / evidence |
|-------|-------------------|
| Deterministic pool/network/guest tests | **PASS** — pool **31** OK; network **8** OK; guest **19** OK (includes failure-path fixture contracts + `VOLUME_PROOF_DONE`-only EXIT cleanup) |
| Failure-path cleanup fixture (static + live) | **PASS** — `podman-failure-cleanup-smoke.sh`; path1 intentional exit **42** after up → EXIT cleanup removed containers+volumes; path2 `up -d --wait` bounded by `timeout 60` (rc=**124**) after partial create → EXIT cleanup removed containers+volumes |
| Fresh image build | **PASS** — `nix build .#ci-runner-guest-image` from dirty `runner-upgrade` tree → `/nix/store/pnwqd0gd8bhv859ks03pfy8c7d3h1219-ci-runner-guest-image` (`result/ci-runner-base.qcow2`, ~1.2G / 1.3 GiB closure). Same derivation as prior correction (guest module unchanged; fixture-only fixes) |
| Isolation + Verdaccio candidate | **PASS** — `ci-candidate-20260810005654-10573`; public HTTPS/DNS ok; Verdaccio HTTPS+TLS ok; resolve `192.168.10.7`; LAN HTTP/ping blocked; host SSH/:80/:3000 blocked; production spare undisturbed |
| Node regression harness | **PASS** — [run 31340711739](https://github.com/tomuradjosip/nixos-ci-runner-validation/actions/runs/31340711739) on harness `final-cleanup-20260810`; candidate `ci-candidate-20260810005726-7532`; Node **24.19.0** / npm / corepack pnpm / esbuild; runner exited 0 → Power down; overlay/seed destroyed |
| Podman success-path smoke | **PASS** — podman **5.8.2**; podman-compose **1.6.0**; `up -d --wait`; volumes `ci-runner-e2e_pgdata` + `ci-runner-e2e_redisdata` present; loopback probes; explicit `down -v` removes containers + named volumes |
| Podman failure-path cleanup | **PASS** — same job step; see failure-path fixture row; no global prune |
| Playwright Chromium smoke | **PASS** — `@playwright/test@1.62.1` (npm latest still 1.62.1); Chromium **151.0.7922.34** / `chromium-1234` + `chromium_headless_shell-1234`; `playwright install chromium` without `--with-deps`; `DEBUG=pw:browser` launch; assertion `ci-runner-playwright-ok`; no missing `.so` |
| Combined E2E | **PASS** — [run 31341399036](https://github.com/tomuradjosip/nixos-ci-runner-validation/actions/runs/31341399036) on harness `final-cleanup-20260810` (~2.5m including failure-path wait bound); candidate `ci-candidate-20260810011348-26308`; Job platform Succeeded; runner exited 0 → Power down; overlay/seed destroyed |
| Named volume removal | **PASS** — after combined `down -v`: Containers **0**, Local Volumes **0**; images may remain (2×336.9MB) |
| Resource measurements | **PASS** — see table below |
| Production base | **unchanged** — `ci-runner-base-20260809191858.qcow2` (`BASE_ID=7e3b6427bda13602`); spare `ci-ephemeral-20260809222011-6654` undisturbed across all candidates; **no** `install-base` / `recycle-idle` during validation (nixosconfig commit/push of this pass happened only afterward as `3fbd854`) |

### Fresh resource measurements (combined job, 4 GiB / 2 vCPU guest)

| Metric | Value |
|--------|-------|
| Baseline `free -m` | total **3918** MiB; used **535**; available **3382** |
| After browser `free -m` | used **800**; available **3117** |
| After teardown `free -m` | used **704**; available **3214** |
| `memory.peak` (job cgroup) | baseline **1012912128** (~966 MiB) → after **2545758208** (~2428 MiB / **~2.37 GiB**) |
| `memory.peak` (`system.slice`) | **2662830080** (~2539 MiB / **~2.48 GiB**) |
| Root FS | before **3.7G/12G (33%)**; after **4.7G/12G (42–43%)** |
| Playwright cache | **656M** (`~/.cache/ms-playwright`) |
| Podman after `down -v` | Images **2 / 336.9MB** reclaimable; Containers **0**; Local Volumes **0** |
| vCPU | `nproc` → **2** |
| OOM | **none** observed |
| Guest RAM/vCPU/`maxGuests` | **unchanged** — 4096 MiB / 2 / 3 |

Chromium launched under root with Playwright’s default `--no-sandbox` (Option A). Headless launch succeeded without extra nix-ld packages. npm `@playwright/test` latest remained **1.62.1** (no pin bump).

### Production deployment

**Forbidden for this pass — confirmed not performed.** Production idle spare remains on the
pre-extension base (`BASE_ID=7e3b6427bda13602`) / `ci-runner-base-20260809191858.qcow2`.
The cleanup corrections were developed and fully validated while uncommitted on top of
`418a457`. After validation they were committed and pushed to `runner-upgrade` as
`3fbd854` (“runner upgrade improvements v2”). They remain unmerged to `main` and were not
installed as the production runner base during this validation cycle. A human must still
explicitly authorize `install-base` / `recycle-idle` before production rotation.

Harness note: fixtures synced onto temporary branch `final-cleanup-20260810` in
`tomuradjosip/nixos-ci-runner-validation` (tip includes failure-path + EXIT cleanup fixes);
**not** merged to harness `main`.

## Agent pool platform (2026-08-15)

Branch `feat/ephemeral-agent-runners` from `main` @ `421fd217bb5646c5ecaaf4ffe25596fb4a1026be`.

### Architecture chosen

- Multi-pool generalization of the existing provisioner (not a second copy of the platform).
- Labels: `nixos-ephemeral-ci` vs `nixos-ephemeral-agent` with distinct domain prefixes
  `ci-ephemeral-*` / `agent-ephemeral-*` and candidate namespaces
  `ci-candidate-*` / `agent-candidate-*`.
- Shared isolated NAT `ci-net` (same iptables policy; no LAN widening).
- Host-wide `hostMaxGuests = 3`; CI `reservedHostSlots = 2`; agent `maxGuests = 1`,
  `desiredIdleCapacity = 1` (polling idle spare).
- Cursor CLI **not** baked in; workflow pins
  `https://downloads.cursor.com/lab/<version>/linux/x64/agent-cli-package.tar.gz`.
- Guest adds `gh`; `CURSOR_API_KEY` remains job-secret only.

### Live host evidence at design time

| Metric | Value (2026-08-15 ~11:13 UTC+2) |
|--------|----------------------------------|
| RAM | 62 GiB total; ~12–13 GiB MemAvailable |
| Swap | 2 GiB, essentially full |
| CPU | 8 threads; load ~6 during CI burst |
| Guests | HA 4 GiB + up to 3× CI 4 GiB; dense Podman |
| Conclusion | Do not raise `hostMaxGuests` above 3 |

### Deterministic tests

| Suite | Result |
|-------|--------|
| `tests/ci_runner_pool_test.py` | **47 PASS** (pool separation, host ceiling, CI reservation, fail-closed, lifecycle) |
| `tests/ci_runner_network_test.py` | **8 PASS** |
| `tests/ci_runner_guest_test.py` | **21 PASS** (incl. `gh` on PATH + Cursor fixture contract) |

### Candidate validation (agent namespace)

| Check | Evidence |
|-------|----------|
| Image | `nix build .#ci-runner-guest-image` → store path with `ci-runner-base.qcow2` (~1.3 GiB) |
| Domain | `agent-candidate-20260815113148-18501` |
| Public HTTPS / DNS | PASS |
| Verdaccio HTTPS (normal TLS) | PASS (`https://verdaccio.iktstudio.com/` → `192.168.10.7`) |
| LAN / SSH / :80 / AdGuard :3000 | blocked as expected |
| `gh` / `git` | `gh version 2.97.0 (nixpkgs)`; git ok |
| Cursor CLI pinned install | `2026.08.11-e8db854` → `agent --version` + `--help` (HOME=/root required under systemd `set -u`) |
| Host docker/libvirt sockets | absent (guest-local Podman socket allowed) |
| Teardown | overlay/seed/domain destroyed; serial retained |
| Production CI spare | **undisturbed** (`ci-ephemeral-20260815111253-16005` before=after) |

### CI starvation conclusion

Under `hostMaxGuests=3` and CI `reservedHostSlots=2`, a busy agent occupies at most one
host slot. Planner unit tests prove CI still receives idle replenishment while an agent is
busy, and combined occupancy never exceeds the host ceiling. **A long-running agent cannot
prevent the PR CI pool from obtaining capacity under this model.**

### Remaining operator steps (post-merge / authorized deploy)

1. `nixos-rebuild switch --impure` (enables agent pool systemd config).
2. `sudo ci-runnerctl install-base <candidate.qcow2>` then `recycle-idle` (or recycle agent only).
3. Confirm `ci-runnerctl status` shows both pools; agent idle=1 when host capacity allows.
4. Optional GitHub smoke: one-job workflow `runs-on: [self-hosted, Linux, X64, nixos-ephemeral-agent]`
   that runs `fixtures/ci-runner-e2e/cursor-cli-smoke.sh` (no Shopforge agent autonomy).
5. Shopforge Developer/Reviewer workflows remain **out of scope** for this change.
