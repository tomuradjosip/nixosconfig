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
- **No Docker/Podman in the guest.**
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
