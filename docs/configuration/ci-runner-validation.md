# Ephemeral CI runner — validation report

Validation of the disposable GitHub Actions runner platform (see
**[CI runner platform](ci-runner.md)** for architecture). Performed on the live host on
**2026-08-09**. Repository under test: `tomuradjosip/shopforge`.

## Result

The platform meets its v1 requirements. A real workflow job ran inside a disposable VM,
the guest was destroyed after exactly one job, and capacity was automatically restored.
Network isolation, boot/teardown reaping, and observability all behave as designed.

## Environment

| Item | Value |
|------|-------|
| Data root | `/data/ci/{base,overlays,seeds,state,logs}` |
| Network | libvirt NAT `ci-net`, bridge `virbr-ci`, `192.168.67.0/24` (active, autostart) |
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
- **Runner updates are manual:** bump `nixpkgs-unstable`, rebuild the guest image, then
  `install-base` and recycle (GitHub in-runner auto-update is intentionally disabled).
- **No Docker/Podman in the guest (v1).**
- **Real boot-time reap trigger** is validated by command/logic and unit wiring; the exact
  systemd firing on a physical reboot was not exercised (host was not rebooted).
- **Monitoring visibility of workflow runs** requires the GitHub App to also have
  **Actions: Read**; only **Administration** is required for runner registration itself.

## Failure policy

`uncertain guest == contaminated guest == destroy`. Overlays are never reset and reused;
each job gets a fresh copy-on-write overlay over the immutable base image.
