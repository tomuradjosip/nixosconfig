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
Run on a **throwaway** private repo `tomuradjosip/nixos-ci-runner-validation` (shopforge was
**not** used or modified), served by an ephemeral runner booted from the 26.05 candidate
image (job `nixos-node-validation`, result **Succeeded**):

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
