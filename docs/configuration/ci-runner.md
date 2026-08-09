# Ephemeral GitHub Actions CI runner platform

Disposable KVM/QEMU/libvirt NixOS VMs provide repository-scoped, one-job GitHub Actions runners. CI jobs never execute on the trusted NixOS host.

> Live validation evidence and results: **[CI runner validation report](ci-runner-validation.md)**.

## Architecture

```text
trusted NixOS host (provisioner / GitHub App key / libvirt)
        |
        | systemd reconcile + reaper
        v
immutable base qcow2  +  per-guest COW overlay  +  throwaway seed ISO
        |
        v
CI guest on dedicated NAT network (ci-net / virbr-ci)
        |
        | --ephemeral runner, label nixos-ephemeral-ci
        v
one GitHub Actions job → guest poweroff → host destroys overlay/seed/domain
```

## Trust boundaries

| Location | Allowed | Forbidden |
|----------|---------|-----------|
| Host | GitHub App private key, libvirt, base images | Job code execution |
| Guest | Short-lived registration token (seed ISO only) | App private key, host mounts/sockets, LAN |
| After teardown | Host journal + metrics | Overlay, seed, runner state |

Guests do **not** attach to `br0`. Docker/Podman are **not** installed in the guest (v1).

## Network policy

- **Network:** libvirt NAT `ci-net`, bridge `virbr-ci`, subnet `192.168.67.0/24`
- **DNS:** guest uses public resolvers `1.1.1.1` / `8.8.8.8` (not LAN AdGuard)
- **FORWARD:** deny CI → RFC1918; allow Internet HTTPS via NAT; optional `services.ciRunner.internalAllowTcp`
- **INPUT on `virbr-ci`:** DHCP only; reject host SSH and other host services

## Modules and units

| Path | Role |
|------|------|
| `modules/ci-runner-host.nix` | Options, dirs, packages, bridge allowlist |
| `modules/ci-runner-network.nix` | libvirt network + iptables isolation |
| `modules/ci-runner-provisioner.nix` | systemd reaper/provisioner/freshness timers |
| `modules/ci-runner-guest.nix` | Guest image definition (stable NixOS + nix-ld) |
| `packages/ci-runner-guest-image.nix` | qcow2 image build (guest = `nixpkgs-guest`) |
| `packages/ci-runner-provisioner.nix` | `ci-runnerctl` |

**systemd:**

- `ci-runner-libvirt-network.service`
- `ci-runner-reaper.service` (boot: `reap-boot`, destroys all leftover CI guests)
- `ci-runner-reaper-soft.service` (periodic: `reap`, never kills running guests)
- `ci-runner-provisioner.service` (+ timer)
- `ci-runner-freshness.service` (+ timer, every 12h: runner-version freshness metrics)
- timers: `ci-runner-reaper.timer`, `ci-runner-provisioner.timer`, `ci-runner-freshness.timer`

**Storage:** `/data/ci/{base,overlays,seeds,state,logs}`

**Domain prefix:** `ci-ephemeral-` (reaper never touches other VMs such as Home Assistant)

## GitHub App setup

The host authenticates to GitHub with a repository-scoped GitHub App (private key stays
host-only). You need four values: `githubOwner`, `githubRepo`, `githubAppId`,
`githubAppInstallationId`, plus the private key `.pem`.

### 1. Create the App

Open the App creation page for the account that **owns the repo**:

- Personal repo: `https://github.com/settings/apps/new`
- Org repo: `https://github.com/organizations/<ORG>/settings/apps/new`

Fill in:

- **GitHub App name**: e.g. `nixos-ephemeral-ci` (must be globally unique)
- **Homepage URL**: anything (e.g. the repo URL)
- **Webhook → Active**: **uncheck** (this platform polls the API; no webhook needed)

### 2. Permissions

Under **Repository permissions** set exactly one:

- **Administration → Read and write**

This is what GitHub requires to create/delete repository self-hosted runners and mint
registration tokens (per the [GitHub docs](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#authentication-requirements)).
Leave everything else **No access**. No account/organization permissions are needed.

Set **"Where can this GitHub App be installed?"** to **Only on this account**, then
**Create GitHub App**.

### 3. App ID

On the App's **General** page, note **App ID** (e.g. `123456`) → `githubAppId`.

### 4. Private key

Same page → **Private keys → Generate a private key** (downloads a `.pem`). Install it
host-only:

```bash
sudo install -o root -g root -m 0600 -D ~/Downloads/<app-name>.*.pem \
  /persist/etc/secrets/ci-runner/github-app.pem
```

The key is referenced only from this path — never from `secrets.nix`, never committed.

### 5. Install on the repo → Installation ID

App → **Install App** → **Install** on the owning account → **Only select repositories**
→ pick the target repo → **Install**. The resulting URL ends with the installation id:

```
https://github.com/settings/installations/<INSTALLATION_ID>          # personal
https://github.com/organizations/<ORG>/settings/installations/<INSTALLATION_ID>  # org
```

That number is `githubAppInstallationId`.

### 6. Non-secret values in secrets.nix

Edit `/etc/secrets/config/secrets.nix`:

```nix
ciRunner = {
  githubOwner = "OWNER";                # user/org that owns the repo
  githubRepo = "REPO";                  # bare repo name, NOT owner/repo
  githubAppId = "123456";               # step 3
  githubAppInstallationId = "12345678"; # step 5
};
```

### 7. Validate before enabling (registers nothing)

Rebuild with `github.enable` still **false**, then:

```bash
sudo ci-runnerctl github-check
```

Expect `PASS: credentials valid`. It mints (and discards) an installation token and a
registration token and lists existing repo runners — it never registers a runner. On
failure the message names which check failed (usually a missing **Administration: Read and
write** or the App not installed on the repo).

### 8. Enable

Only after the check passes, in `configuration.nix`:

```nix
services.ciRunner = {
  enable = true;
  github.enable = true;
};
```

After the next rebuild, `ci-runner-provisioner` provisions one warm-spare ephemeral runner
and keeps it registered until it picks up a job.

**Gotchas:**

- The App, its installation, and the repo must all be under the same `githubOwner`.
- `githubRepo` is the bare repo name (no `owner/` prefix).
- Do **not** commit private keys or tokens.

## Runner label

Consuming workflows should target:

```yaml
runs-on: [self-hosted, Linux, X64, nixos-ephemeral-ci]
```

This repository does not own application workflow YAML.

## NixOS base

| Component | Package set | Release |
|-----------|-------------|---------|
| Host (provisioner/control plane) | `nixpkgs` | `nixos-25.05` |
| **Disposable guest** | `nixpkgs-guest` | **`nixos-26.05`** (current supported stable) |
| `github-runner` only | `nixpkgs-unstable` | current runner |

The guest OS is a dedicated flake input (`nixpkgs-guest`) so the disposable image can track
a **supported stable** NixOS release independently of the host's upgrade cadence. 25.05
"Warbler" reached end-of-support 2025-12-31; the guest now runs 26.05 "Yarara" (supported
through 2026-12-31). Only `github-runner` is sourced from unstable (see below).

To move the guest to a newer stable: bump `nixpkgs-guest` in `flake.nix`/`flake.lock`,
rebuild the guest image, validate, `install-base`, and recycle.

> The host itself is still on `nixos-25.05` (also end-of-support). Upgrading the host OS is
> a separate, larger change out of scope of the CI-runner platform and is tracked separately.

## Runner update model

`--disableupdate` is an **intentional architecture decision**, not a limitation:

- The runner executable lives in the immutable `/nix/store`. GitHub's in-place self-update
  (download + `tar -xzf` over its own directory) cannot mutate that installation and would
  crash-loop the listener. So self-update is disabled and **Nix / the guest image is the
  sole update authority**.
- GitHub still requires self-hosted runners to stay current
  ([docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners#controlling-runner-software-updates-on-self-hosted-runners)):
  - **Registration minimum:** a runner must be **≥ 2.329.0** to (re)register.
  - **30-day window:** once a newer release is published you must update within **30 days**,
    or GitHub stops queuing jobs to the runner.
  - **Critical security updates** can pause job queuing immediately, regardless of the window.
- Even current NixOS **stable** lags (26.05 ships 2.335.1 vs latest 2.336.0), so the runner
  is pinned from `nixpkgs-unstable` to stay inside the window without moving the whole guest
  OS off stable.

Image-managed update mechanism:

```text
bump pinned runner (nix flake update nixpkgs-unstable)
  → rebuild base qcow2
  → validate candidate (dummy isolation + generic Node CI)
  → install candidate atomically (install-base)
  → recycle clean spare
```

Freshness is **monitored** (see [Runner freshness](#runner-freshness-monitoring)) so the
30-day deadline is observable rather than relying on memory. Monitoring never edits
`flake.lock`; the Git repository stays authoritative over inputs.

## Node / generic Linux-binary compatibility

Consuming repositories own their **application toolchain versions**; the guest owns only the
generic ability to run conventional, dynamically linked Linux binaries that GitHub Actions
downloads at job time.

- `programs.nix-ld.enable = true` in the guest installs a shim at
  `/lib64/ld-linux-x86-64.so.2` (which NixOS otherwise lacks) so downloaded binaries — e.g.
  the Node runtime fetched by `actions/setup-node`, and prebuilt native npm packages — can
  execute. The runner service also exports `NIX_LD` / `NIX_LD_LIBRARY_PATH` (nix-ld's
  `sessionVariables` do not reach systemd services), which propagate to job steps.
- The nix-ld library set is the module default (zlib, zstd, `stdenv.cc.cc`/libstdc++,
  openssl, …) — the minimum generic set, deliberately **not** expanded until an actual
  validation failure demonstrates a specific missing library.
- The runner service PATH includes the standard archive/text utilities (`tar`, `gzip`, `xz`,
  `unzip`, `grep`, `sed`, `awk`, `find`) that the runner uses to unpack actions and that
  ordinary `run:` steps expect. These are generic tools, not application toolchains.

No particular Node version, package-manager version, or build command is baked into the
image. See the [validation report](ci-runner-validation.md) for the real disposable Node CI
proof (setup-node → Node 24, npm, Corepack/pnpm, and a prebuilt native tool via nix-ld).

## Support boundary

- GitHub officially lists Ubuntu and several other Linux distributions for self-hosted
  runners. **NixOS is not on GitHub's published supported-OS list.**
- NixOS is intentionally retained here because the guest image is **declaratively built and
  disposable**, and this is backed by a successful real Node CI validation on the disposable
  guest (setup-node, npm, Corepack, and a prebuilt native binary all run via nix-ld).
- Ubuntu remains a **fallback, not the current target**. Reconsider it only on evidence of
  *systemic* incompatibility (standard Actions repeatedly failing due to NixOS, many
  downloaded binaries needing ad-hoc fixes, growing image-specific hacks). A one-off need for
  nix-ld or an extra generic tool on PATH is **not** such a reason. This does not imply
  official GitHub support for NixOS.

## Runner freshness monitoring

`ci-runner-freshness.timer` (every 12h) runs `ci-runnerctl freshness`, which compares the
baked runner version against the latest published GitHub Actions runner release via the
public, unauthenticated releases API (no GitHub credentials). It is **observe-only** — it
never mutates `flake.lock`, rebuilds, or deploys:

```text
monitor detects runner behind latest release
  → metric / warning
  → human updates committed flake.lock
  → candidate image rebuilt + validated
  → new base deployed
```

Textfile metrics (`/var/lib/node_exporter_textfile/ci_runner_freshness.prom`):

- `ci_runner_baked_version_info{version=…}` — baked runner version
- `ci_runner_latest_version_info{version=…}` — latest published release
- `ci_runner_update_available` — 1 if baked is behind latest
- `ci_runner_latest_release_timestamp` — publish time of latest release
- `ci_runner_update_deadline_timestamp` — latest release + 30d (0 when up to date/unknown)
- `ci_runner_freshness_check_timestamp` / `ci_runner_freshness_check_success`

## Build / install base image

```bash
nix build /home/toka/nixosconfig#ci-runner-guest-image -L
sudo ci-runnerctl install-base result/ci-runner-base.qcow2
```

### Maintenance lifecycle

Human-controlled source changes (Git stays authoritative over flake inputs):

1. Update a flake input in `flake.nix`/`flake.lock` and **commit** it:
   - `nixpkgs-unstable` → newer `github-runner` (freshness monitor flags this), or
   - `nixpkgs-guest` → newer supported stable NixOS.
2. Build a candidate base image: `nix build .#ci-runner-guest-image -L`.
3. Validate the candidate **without replacing the live base** (boot under a non
   `ci-ephemeral-*` name so the reaper/reconciler ignore it):
   - dummy isolation proof, then
   - a real disposable Node CI run on a **throwaway** repo where appropriate.

Operational install/recycle (once the candidate passes):

4. `sudo ci-runnerctl install-base <candidate.qcow2>` — atomic `base/current.qcow2` swap.
5. `sudo ci-runnerctl destroy-all` (or let the reaper clear the idle spare).
6. `sudo ci-runnerctl reconcile` — provision a fresh spare from the new base.
7. Verify the new runner registers and is `Listening for Jobs`.
8. Keep the previous base under `/data/ci/base/` for rollback; prune older unreferenced
   bases later once no overlays reference them.

> Changing the provisioner package (`ci-runnerctl`) alters the `ci-runner-reaper.service`
> `ExecStart`, so a `nixos-rebuild switch` will re-run the fail-closed boot reaper once and
> recycle the idle spare. This self-heals (reconcile provisions a fresh spare) and is
> expected during upgrades of the platform code itself.

## Validating a candidate image (regression harness)

Validate a candidate **before** `install-base`, without disturbing the live spare. The key
safety rule: boot candidate guests under a name that does **not** start with `ci-ephemeral-`
(e.g. `ci-candidate-…`), because the reaper/reconciler only ever act on `ci-ephemeral-*`
domains. Manually create an overlay over the candidate qcow2, build a `CI_SEED` ISO (label
`CI_SEED`, containing `MODE=` + probe/runner vars — same schema as `make_seed_iso` in
`packages/ci-runner-provisioner.nix`), then `virt-install` onto `ci-net` with a serial log.

**Node compatibility regression repo.** A dedicated throwaway repo,
[`tomuradjosip/nixos-ci-runner-validation`](https://github.com/tomuradjosip/nixos-ci-runner-validation),
holds a `node-validation.yml` workflow (`runs-on: [self-hosted, Linux, X64, nixos-ephemeral-ci]`)
that exercises the generic Node path: `actions/setup-node` (Node 24) → `node`/`npm` → ordinary
JS → `npm install` of a prebuilt native tool (esbuild) → run it + a package script → Corepack
`pnpm` bootstrap. It intentionally contains **no** application code and is kept for future
debugging. It is **not** used by the live platform (which is scoped to the real app repo via
the GitHub App); it is served on demand by a candidate runner registered with a directly
minted token, so it never touches the App or the production repo.

Re-run it against a candidate (real disposable GitHub job), booting under a `ci-candidate-*`
name so the live spare is untouched:

```bash
REPO=tomuradjosip/nixos-ci-runner-validation
# 1. Mint a repo-scoped registration token via gh (uses your user token, not the App):
TOKEN=$(gh api -X POST "/repos/$REPO/actions/runners/registration-token" -q .token)
# 2. Boot a candidate runner guest named ci-candidate-* over the candidate qcow2, with a
#    CI_SEED ISO carrying MODE=runner / REPO_URL=https://github.com/$REPO / REGISTRATION_TOKEN
#    / RUNNER_NAME / RUNNER_LABELS (see make_seed_iso + define_and_start for the exact XML).
# 3. Wait for "Listening for Jobs" in the serial log, then dispatch:
gh workflow run node-validation.yml -R "$REPO" --ref main
gh run watch -R "$REPO"      # expect: success; runner deregisters + guest powers off
# 4. Tear the candidate down (virsh destroy/undefine --remove-all-storage, rm overlay/seed).
```

Dummy isolation proof for a candidate uses the same non-`ci-ephemeral-*` boot with
`MODE=dummy` (no GitHub); expect the probe lines in [Troubleshooting](#troubleshooting).

## Operations

```bash
sudo ci-runnerctl status
sudo ci-runnerctl metrics
sudo ci-runnerctl freshness      # compare baked runner vs latest GitHub release (observe-only)
sudo ci-runnerctl github-check   # validate App creds/permissions (registers nothing)
sudo ci-runnerctl reap
sudo ci-runnerctl reconcile
sudo ci-runnerctl provision      # provision one ephemeral runner guest (GitHub enabled)
sudo ci-runnerctl dummy          # isolation proof without GitHub
sudo ci-runnerctl destroy-all    # safe: prefix-filtered only
journalctl -u ci-runner-provisioner -u ci-runner-reaper -u ci-runner-freshness -t ci-runnerctl -f
virsh list --all
virsh net-info ci-net
```

### Metrics

Written to `/var/lib/node_exporter_textfile/ci_runner.prom`:

- `ci_runner_clean_capacity`
- `ci_runner_guest_active`
- `ci_runner_provision_success_timestamp`
- `ci_runner_provision_failures_total`
- `ci_runner_teardown_failures_total`
- `ci_runner_orphan_cleanup_total`
- `ci_runner_overlay_bytes`

Runner-freshness metrics are written separately to `ci_runner_freshness.prom` (see
[Runner freshness monitoring](#runner-freshness-monitoring)).

### Host reboot

On boot: libvirt network → reaper destroys any `ci-ephemeral-*` leftovers → provisioner restores capacity when GitHub is enabled. CI guests are never autostarted.

### Disable safely

```nix
services.ciRunner.enable = false;
```

Then rebuild, and optionally `sudo ci-runnerctl destroy-all` before disabling if the tool is still on PATH.

## Troubleshooting

**Where to look first**

| Source | Command |
|--------|---------|
| Guest boot + runner + job output (per guest) | `sudo sed 's/\x1b\[[0-9;]*m//g' /data/ci/logs/<domain>.serial.log` (strip ANSI) |
| Host provisioner/reaper/freshness | `journalctl -u ci-runner-provisioner -u ci-runner-reaper -u ci-runner-reaper-soft -u ci-runner-freshness -t ci-runnerctl` |
| Current platform state | `sudo ci-runnerctl status` / `sudo ci-runnerctl metrics` |
| GitHub App creds/permissions | `sudo ci-runnerctl github-check` (registers nothing) |
| Runner version vs latest | `sudo ci-runnerctl freshness` |

The guest has **no SSH** (serial console only, by design). All guest diagnostics come from the
serial log; job stdout/stderr is also visible in the GitHub Actions run UI.

**Runner won't register / picks up no jobs**
- `Current runner version` in the serial log must be **≥ 2.329.0** and within **30 days** of
  the latest release (`ci-runnerctl freshness` → `update_available`). If behind, bump
  `nixpkgs-unstable`, rebuild, `install-base`, recycle.
- Job stuck "queued": confirm the workflow `runs-on` labels match `nixos-ephemeral-ci,self-hosted,Linux,X64`.

**Downloaded binary fails to run (ELF / loader issues)** — the most likely NixOS-specific class:
- Symptoms: `No such file or directory` when executing a downloaded binary that clearly
  exists, `cannot execute: required file not found`, or `error while loading shared libraries`.
- These mean the binary's hardcoded interpreter (`/lib64/ld-linux-x86-64.so.2`) or a shared
  library isn't resolvable. This platform relies on `programs.nix-ld` (guest) + `NIX_LD` /
  `NIX_LD_LIBRARY_PATH` exported to the runner service. Verify inside a job:
  `ls -l /lib64/ld-linux-x86-64.so.2` (should point at `…-nix-ld-…/libexec/nix-ld`) and
  `echo "$NIX_LD $NIX_LD_LIBRARY_PATH"`.
- Fix path: if a *specific* library is missing (`libfoo.so.N`), add that package to
  `programs.nix-ld.libraries` in `modules/ci-runner-guest.nix` — the **smallest** addition
  that resolves it, then rebuild + validate. Do not add broad library sets preemptively.

**`<tool>: command not found` in a job step**
- The job PATH is the `ci-runner-lifecycle` service `path` in `modules/ci-runner-guest.nix`
  (plus whatever `setup-*` actions prepend). If a *generic* Linux CI utility is missing, add
  its package there (this is how `tar`/`gzip`/… were added). Application toolchains are **not**
  added here — repositories install those via `actions/setup-*`.

**Guest didn't power off / overlay left behind**
- `uncertain guest == destroy`: `sudo ci-runnerctl destroy <ci-ephemeral-…>` (prefix-guarded)
  or `sudo ci-runnerctl reap` (soft, leaves running guests). `ci_runner_teardown_failures_total`
  and `ci_runner_orphan_cleanup_total` track these.

**Candidate validation** — see [Validating a candidate image](#validating-a-candidate-image-regression-harness);
always boot candidates as `ci-candidate-*` so the reaper leaves the live spare alone.

## Failure policy

`uncertain guest == contaminated guest == destroy`. Writable overlays are never reset and reused for another job.
