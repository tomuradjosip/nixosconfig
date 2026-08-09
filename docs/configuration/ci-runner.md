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
| `modules/ci-runner-provisioner.nix` | systemd reaper/provisioner timers |
| `modules/ci-runner-guest.nix` | Guest image definition |
| `packages/ci-runner-guest-image.nix` | qcow2 image build |
| `packages/ci-runner-provisioner.nix` | `ci-runnerctl` |

**systemd:**

- `ci-runner-libvirt-network.service`
- `ci-runner-reaper.service` (boot: `reap-boot`, destroys all leftover CI guests)
- `ci-runner-reaper-soft.service` (periodic: `reap`, never kills running guests)
- `ci-runner-provisioner.service` (+ timer)
- timers: `ci-runner-reaper.timer`, `ci-runner-provisioner.timer`

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

## Runner version / updates

The guest's `github-runner` is pinned from the `nixpkgs-unstable` flake input (stable
`nixos-25.05` lags behind GitHub's required minimum). The runner is configured with
`--disableupdate` because it lives in the immutable `/nix/store` and cannot self-update
(GitHub's in-place `tar -xzf` update fails). GitHub also refuses connections from
deprecated runner versions, so the version must stay current.

To update the runner: `nix flake update nixpkgs-unstable`, rebuild the guest image, then
`install-base` and recycle. Do not rely on GitHub's in-runner auto-update.

## Build / install base image

```bash
nix build /home/toka/nixosconfig#ci-runner-guest-image -L
sudo ci-runnerctl install-base result/ci-runner-base.qcow2
```

Safe update flow:

1. Build a new base image
2. `ci-runnerctl install-base` (atomic symlink `base/current.qcow2`)
3. `sudo ci-runnerctl destroy-all` (or let reaper clear idle spare)
4. `sudo ci-runnerctl reconcile` to provision a replacement
5. Prune old files under `/data/ci/base/` when no overlays reference them

## Operations

```bash
sudo ci-runnerctl status
sudo ci-runnerctl metrics
sudo ci-runnerctl github-check   # validate App creds/permissions (registers nothing)
sudo ci-runnerctl reap
sudo ci-runnerctl reconcile
sudo ci-runnerctl provision      # provision one ephemeral runner guest (GitHub enabled)
sudo ci-runnerctl dummy          # isolation proof without GitHub
sudo ci-runnerctl destroy-all    # safe: prefix-filtered only
journalctl -u ci-runner-provisioner -u ci-runner-reaper -t ci-runnerctl -f
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

### Host reboot

On boot: libvirt network → reaper destroys any `ci-ephemeral-*` leftovers → provisioner restores capacity when GitHub is enabled. CI guests are never autostarted.

### Disable safely

```nix
services.ciRunner.enable = false;
```

Then rebuild, and optionally `sudo ci-runnerctl destroy-all` before disabling if the tool is still on PATH.

## Failure policy

`uncertain guest == contaminated guest == destroy`. Writable overlays are never reset and reused for another job.
