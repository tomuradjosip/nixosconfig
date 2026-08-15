# Ephemeral GitHub Actions runner platform

Disposable KVM/QEMU/libvirt NixOS VMs provide repository-scoped, one-job GitHub Actions runners. Job code never executes on the trusted NixOS host.

The platform runs **two independently labelled pools** that share one physical-host guest ceiling:

| Pool | Label | Domain prefix | Purpose |
|------|-------|---------------|---------|
| CI | `nixos-ephemeral-ci` | `ci-ephemeral-*` | PR/push CI (Shopforge and validation harness) |
| Agent | `nixos-ephemeral-agent` | `agent-ephemeral-*` | Long-running Shopforge Developer / Reviewer agents |

Consuming workflows target exactly one label. A job with `runs-on: nixos-ephemeral-ci` cannot land on an agent guest, and vice versa.

> Live validation evidence and results: **[CI runner validation report](ci-runner-validation.md)**.

## Architecture

```text
trusted NixOS host (provisioner / GitHub App key / libvirt)
        |
        | systemd reconcile (30s) + reaper  — flock(provision.lock)
        | multi-pool planner under hostMaxGuests + CI reserved slots
        v
immutable base qcow2  +  per-guest COW overlay  +  throwaway seed ISO
        |
        +-- CI guest     label nixos-ephemeral-ci      prefix ci-ephemeral-*
        +-- Agent guest  label nixos-ephemeral-agent   prefix agent-ephemeral-*
        |
        | both on shared isolated NAT (ci-net / virbr-ci)
        v
one GitHub Actions job → guest poweroff → host destroys overlay/seed/domain
        |
        v
reconciler restores each pool's desiredIdleCapacity (subject to per-pool max
and the shared host ceiling; CI provisions before agent under contention)
```

Shopforge remote-agent flow (application workflows are out of scope here):

```text
phone / workflow_dispatch
        ↓
Developer on nixos-ephemeral-agent  →  branch + draft PR  →  agent guest gone
        ↓
PR CI on nixos-ephemeral-ci (independent pool; CI reserved slots protect this)
        ↓
Reviewer on a fresh nixos-ephemeral-agent guest  →  gone
```

## Trust boundaries

| Location | Allowed | Forbidden |
|----------|---------|-----------|
| Host | GitHub App private key, libvirt, base images | Job code execution; Cursor API keys; app write tokens |
| Guest | Short-lived registration token (seed ISO only); job-level Actions secrets at runtime | App private key, host mounts/sockets, LAN |
| After teardown | Host journal + metrics | Overlay, seed, runner state |

Guests do **not** attach to `br0`. Docker Engine is **not** installed. **Rootful Podman**
is available **inside disposable guests only** (guest-local storage/networking; no host
Docker/Podman socket; no Docker socket compatibility alias).

**Secrets boundary:** `CURSOR_API_KEY`, GitHub write tokens, and application secrets must
arrive only as GitHub Actions job secrets at execution time. They are never baked into the
NixOS image, seed ISO, repository, or host configuration. Host GitHub App auth is used only
to register/list ephemeral runners.

## Network policy

CI and agent pools **share** the same isolated libvirt NAT (`ci-net`). A second network would
not improve isolation under the same iptables policy and would complicate Verdaccio/DNS
exceptions. Agent guests are more privileged logically (may push branches / open PRs via
job secrets) — that is a reason to keep the same narrow policy, not to widen it.

- **Network:** libvirt NAT `ci-net`, bridge `virbr-ci`, subnet `192.168.67.0/24`
- **DNS:** guest uses DHCP → libvirt dnsmasq on the gateway (`192.168.67.1`). That dnsmasq serves only `services.ciRunner.internalDnsHosts` as static records and forwards all other names to public resolvers (`1.1.1.1` / `8.8.8.8`). Guests do **not** use LAN AdGuard or the router resolver.
- **FORWARD:** deny guest → RFC1918; allow Internet HTTPS via NAT; optional `internalAllowTcp`
- **INPUT on `virbr-ci`:** DHCP + DNS to the gateway only; optional `hostAllowTcp`; reject SSH, AdGuard UI, and all other host services

### Explicit internal hostname access

Approved internal HTTPS dependencies are configured generically — hostname in host config, not special-cased in module logic:

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

| Knob | Path | Meaning |
|------|------|---------|
| `internalDnsHosts` | ci-net dnsmasq | Name → IP inside ci-net only |
| `hostAllowTcp` | iptables **INPUT** (`ci-runner-in`) | guest → host-local `address:port` |
| `internalAllowTcp` | iptables **FORWARD** (`ci-runner-fwd`) | guest → other RFC1918 `address:port` |

**Why INPUT vs FORWARD matters:** `verdaccio.iktstudio.com` resolves to `192.168.10.7`, which is this host's `br0` address where Traefik publishes `:443`. Packets from `virbr-ci` to a local host address hit **INPUT**, not FORWARD. Broad LAN access remains denied.

**TLS:** guests must use normal certificate verification (`curl` without `-k` / `--insecure`).

**Shared Traefik IP limitation:** allowing `192.168.10.7:443` permits TCP to every TLS virtual host on that listener if the guest supplies another Host/SNI. Acceptable for disposable guests + explicit allowlist.

**DNS is not authorization:** resolving a name does not grant access. Firewall rules remain the boundary.

## Modules and units

| Path | Role |
|------|------|
| `modules/ci-runner-host.nix` | Options, multi-pool config, dirs, packages |
| `modules/ci-runner-network.nix` | Shared libvirt network + iptables isolation |
| `modules/ci-runner-provisioner.nix` | systemd reaper/provisioner/freshness timers |
| `modules/ci-runner-guest.nix` | Guest image (stable NixOS + nix-ld + gh + Podman) |
| `packages/ci-runner-guest-image.nix` | qcow2 image build |
| `packages/ci-runner-provisioner.nix` | `ci-runnerctl` + baked `pools.json` |
| `packages/ci-runner-network-lib.nix` | Pure DNS/iptables render helpers |
| `packages/ci-runner-pool.py` | Deterministic multi-pool planner (unit-tested) |
| `tests/ci_runner_pool_test.py` | Planner unit tests (incl. host capacity / pool separation) |
| `tests/ci_runner_network_test.py` | Network render unit tests |
| `tests/ci_runner_guest_test.py` | Guest capability invariants |
| `fixtures/ci-runner-e2e/` | Podman / Playwright / Cursor CLI smokes |

**systemd** (single reconciler for all pools — one `flock`, no cross-pool races):

- `ci-runner-libvirt-network.service`
- `ci-runner-reaper.service` (boot: `reap-boot`, destroys leftover production guests in **all** pools)
- `ci-runner-reaper-soft.service` (periodic: `reap`, never kills running guests)
- `ci-runner-provisioner.service` (+ timer every **30s**)
- `ci-runner-freshness.service` (+ timer, every 12h)
- timers: `ci-runner-reaper.timer`, `ci-runner-provisioner.timer`, `ci-runner-freshness.timer`

**Storage:** `/data/ci/{base,overlays,seeds,state,logs}`

| Path | Role |
|------|------|
| `/data/ci/base/current.qcow2` | Symlink to the immutable base used for **new** guests |
| `/data/ci/state/provision.lock` | `flock` around full reconcile / status / validate |
| `/data/ci/state/guests/<name>.env` | Per-guest state (base pin, overlay, pool id, …) |
| `/data/ci/state/host-pools.json` | Last multi-pool planner output |
| `/data/ci/state/pool.json` | CI subset (legacy consumers) |
| `/data/ci/logs/<name>.serial.log` | Guest serial console |

**Domain prefixes:**

| Prefix | Managed by production reaper/reconciler? |
|--------|------------------------------------------|
| `ci-ephemeral-*` | Yes — CI pool |
| `agent-ephemeral-*` | Yes — agent pool |
| `ci-candidate-*` | **Never** — CI candidate validation |
| `agent-candidate-*` | **Never** — agent candidate validation |

## Capacity model (host-wide)

Independent pools must not each consume a full per-pool max and oversubscribe the host.

| Option | Live value | Meaning |
|--------|------------|---------|
| `hostMaxGuests` | **3** | Dual meaning (same number by design): (1) hard ceiling on **production** guests across all pools; (2) default **physical** safety ceiling for any runner-like VM including candidates |
| CI `maxGuests` | 3 | Per-pool cap (still subject to host ceiling) |
| CI `desiredIdleCapacity` | 1 | Keep one online idle CI spare when capacity allows |
| CI `reservedHostSlots` | **2** | Lower-priority pools may not *consume capacity that would leave CI below this floor* when allocating **new** guests |
| CI `priority` | 100 | Higher priority when allocating **new** provisions under host contention |
| Agent `maxGuests` | 1 | At most one agent guest (Developer/Reviewer are sequential) |
| Agent `desiredIdleCapacity` | 1 | One always-idle agent spare (polling demand model) |
| Agent `priority` | 50 | Lower priority for **new** provisions under host contention |
| Guest RAM / vCPU (both pools) | 4096 MiB / 2 | Same disposable image sizing |

**`priority` is not preemption.** It only affects how free host slots are assigned to *new* provisions. An already-running idle agent is **not** automatically destroyed because CI wants a third guest. The CI floor guarantee is: under the reservation model, the agent pool cannot *consume* capacity required to preserve two host slots for CI (agent max effective occupancy is `hostMaxGuests − reservedHostSlots = 1`). That is sufficient for Developer → CI → Reviewer.

**Creation-site guards (defense in depth):** `ci-runnerctl provision` and reconcile both call `provision_one`, which refuses under the shared `flock` if creating one more production guest would exceed per-pool `maxGuests`, production `hostMaxGuests`, or the physical ceiling (production + candidates). Planner arithmetic alone is not trusted.

**CI starvation answer:** with `reservedHostSlots = 2` and `hostMaxGuests = 3`, a busy agent occupies at most one host slot. At least two host slots remain available for CI. A long-running Developer/Reviewer agent therefore **cannot** reduce CI below its protected two-slot floor under this model. When the host is already full of CI guests (3), the agent waits — that is intentional (CI priority for *new* slots), not CI starvation.

**Live host evidence (2026-08-15):** Intel i3-14100 (8 threads), 62 GiB RAM, ~12–13 GiB MemAvailable with swap 2 GiB often full while 3×4 GiB CI guests + HA (4 GiB) + dense Podman run. Raising `hostMaxGuests` above 3 is unsafe without right-sizing. Do not increase capacity merely to avoid this design.

### Candidate physical admission

Candidates (`*-candidate-*`) are excluded from production reconciliation (correct for lifecycle ownership) but still consume RAM/vCPU. By default `validate-candidate` **refuses** to start if `production + existing candidates + 1 > hostMaxGuests`.

```bash
# Fail-closed (default)
sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2 --pool agent

# Explicit operator bypass (conspicuous warning; not for normal automation)
sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2 --pool agent \
  --allow-capacity-overcommit
```

Candidate admission and production provision share `provision.lock`, so two concurrent operations cannot both observe one free slot and overcommit.

### Idle / demand strategy (agent)

The platform is polling-based (no `workflow_job` webhooks, no ARC, no Kubernetes).

| Strategy | Pros | Cons |
|----------|------|------|
| `desiredIdleCapacity = 0` | No warm RAM cost | Queued agent jobs never start without another demand signal |
| `desiredIdleCapacity = 1` | Reliable first version; agent job starts immediately | One warm 4 GiB guest while unused; reduces CI burst headroom while warm |

**Chosen:** agent `desiredIdleCapacity = 1` — simplest reliable architecture consistent with safe host capacity and CI reservation. Quiet steady state is typically 1 CI idle + 1 agent idle (= 2 of 3 host slots). Under CI load of 3, the agent spare is deferred until a slot frees.

### Authority and fail-closed behaviour

| Source | Authoritative for |
|--------|-------------------|
| GitHub API `status` + `busy` on [list runners](https://docs.github.com/en/rest/actions/self-hosted-runners) (`GET /repos/{owner}/{repo}/actions/runners`) | Whether a registered runner is idle or busy |
| libvirt | Whether a guest domain exists / its power state |

- **GitHub API failure:** fail-closed — do **not** overprovision; retain running guests; destroy only unambiguous local dead state (e.g. shut off); retry on the next poll.
- **Installation tokens** last **1 hour** ([GitHub App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)); `ci-runnerctl` caches them host-only for ~**55 minutes**.
- **Rate limit:** App installation tokens typically get **5,000 requests/hour** ([REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)). A 30s poll is ~120 list calls/h plus occasional registration-token mints — well inside budget. Guest boot+register is ~1–2 minutes, so sub-minute polling notices busy → idle-deficit promptly without webhooks.

### Pool states

| State | Meaning |
|-------|---------|
| `provisioning` | Guest running; GitHub runner not yet online; within grace (`provisioningGraceSec`, default 300s) |
| `idle` | GitHub runner online and `busy == false` |
| `busy` | GitHub runner online and `busy == true` |
| `shutting_down` | libvirt in-shutdown → destroy |
| `stale` | libvirt not running (shut off / crashed / …) → destroy |
| `uncertain` | Running but unclassifiable; destroyed only when GitHub is reachable and grace has elapsed; retained during GitHub outage |

Planner: `packages/ci-runner-pool.py` (no I/O). Bash `ci-runnerctl` collects the snapshot and executes the plan under lock.

### Per-guest state and rolling base replacement

Each managed guest has `/data/ci/state/guests/<name>.env` including at least:

`BASE_PATH`, `BASE_SHA256`, `BASE_ID`, `SERIAL_LOG`, `OVERLAY`, `CREATED_AT_UNIX`

Overlays are created with `qemu-img` backing the **resolved immutable base path** (not the `current.qcow2` symlink), so `install-base` can rotate the symlink for future guests while busy guests finish on their pinned overlay.

| Command | Effect |
|---------|--------|
| `install-base <qcow2>` | Installs a new immutable base and points `current.qcow2` at it for **future** guests. Does not touch busy guests. |
| `recycle-idle` | Destroys only **idle** production guests, then reconciles so replacements come from the new current base. Busy guests are left alone. |

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
  desiredIdleCapacity = 1;
  maxGuests = 3;   # evidence-based for this host; architectural ceiling 10
};
```

After the next rebuild, `ci-runner-provisioner` keeps the idle pool at
`desiredIdleCapacity` (subject to `maxGuests`), registering ephemeral runners until each
picks up a job.

**Gotchas:**

- The App, its installation, and the repo must all be under the same `githubOwner`.
- `githubRepo` is the bare repo name (no `owner/` prefix).
- Do **not** commit private keys or tokens.

## Runner labels

```yaml
# PR / push CI
runs-on: [self-hosted, Linux, X64, nixos-ephemeral-ci]

# Shopforge Developer / Reviewer agents (workflows not in this repo)
runs-on: [self-hosted, Linux, X64, nixos-ephemeral-agent]
```

If a job stays queued, check which label it requested:

| Symptom | Likely cause |
|---------|--------------|
| Queued on `nixos-ephemeral-ci`, `ci_runner_saturated 1` / `runner_pool_saturated{pool="ci"} 1` | CI pool at capacity (or host full of CI) |
| Queued on `nixos-ephemeral-agent`, host full / agent busy | Agent max=1 already occupied, or host at `hostMaxGuests` with CI priority holding slots |
| Queued forever, `runner_pool_github_ok 0` | GitHub App / API outage (fail-closed) |

This repository does not own application workflow YAML.

## Cursor CLI (agent guests)

**Decision:** Cursor CLI is **not** baked into the guest image. Consuming workflows install a **pinned** lab build from the official downloads URL scheme documented by Cursor (`https://downloads.cursor.com/lab/<version>/linux/x64/agent-cli-package.tar.gz`). That keeps an auditable version boundary in the application repo and avoids an unpinned `curl \| bash` dependency in NixOS.

Guest prerequisites for that install:

- `curl`, `cacert`, `bash`, writable `$HOME`
- `programs.nix-ld` for dynamically linked CLI binaries
- `git`, `gh` on PATH (agent workflows that push branches / open PRs)

Platform smoke: `fixtures/ci-runner-e2e/cursor-cli-smoke.sh` (version/help only; no autonomous agent).

`CURSOR_API_KEY` remains a GitHub Actions job secret only.

## NixOS base

| Component | Package set | Release |
|-----------|-------------|---------|
| Host (provisioner/control plane) | `nixpkgs` | `nixos-25.05` |
| **Disposable guest** | `nixpkgs-guest` | **`nixos-26.05`** (current supported stable) |
| `github-runner` | `nixpkgs-unstable` | current runner |
| `podman-compose` | `nixpkgs-unstable` | **1.6.0** (`up --wait`) |

The guest OS is a dedicated flake input (`nixpkgs-guest`) so the disposable image can track
a **supported stable** NixOS release independently of the host's upgrade cadence. 25.05
"Warbler" reached end-of-support 2025-12-31; the guest now runs 26.05 "Yarara" (supported
through 2026-12-31). Only narrow pins (`github-runner`, `podman-compose`) come from
unstable — the guest OS itself stays on stable.

To move the guest to a newer stable: bump `nixpkgs-guest` in `flake.nix`/`flake.lock`,
rebuild the guest image, validate, `install-base`, and `recycle-idle`.

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
  → validate-candidate (dummy isolation; optional --github-repo regression)
  → install-base (switches current for future guests)
  → recycle-idle (destroy idle only; busy finish on pinned overlays)
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
  the Node runtime fetched by `actions/setup-node`, prebuilt native npm packages, and
  Playwright-managed Chromium — can execute. The runner service also exports `NIX_LD` /
  `NIX_LD_LIBRARY_PATH` (nix-ld's `sessionVariables` do not reach systemd services), which
  propagate to job steps.
- The nix-ld library set is the module default (zlib, zstd, `stdenv.cc.cc`/libstdc++,
  openssl, …) **plus** Chromium runtime libraries required for Playwright-downloaded
  browsers (see [Playwright Chromium](#playwright-chromium-support)).
- The runner service PATH includes the standard archive/text utilities (`tar`, `gzip`, `xz`,
  `unzip`, `grep`, `sed`, `awk`, `find`) that the runner uses to unpack actions and that
  ordinary `run:` steps expect, plus guest Podman / `podman-compose`. These are generic
  platform tools, not application toolchains.

No particular Node version, package-manager version, Medusa version, Playwright npm version,
or browser revision is baked into the image. See the [validation report](ci-runner-validation.md)
for the real disposable Node CI proof (setup-node → Node 24, npm, Corepack/pnpm, and a
prebuilt native tool via nix-ld).

## Podman inside disposable guests

Rootful **Podman** (not Docker Engine) is enabled **only inside the disposable guest**:

| Property | Value |
|----------|-------|
| Engine | Podman (rootful) |
| Why rootful | Job code already runs as root in the throwaway VM (accepted Option A) |
| Storage / networks | Guest-local only; destroyed with the overlay |
| Host sockets | **None** — no host Podman/Docker/libvirt socket passthrough |
| Docker Engine | Disabled (`virtualisation.docker.enable = false`) |
| Docker CLI alias | Disabled (`dockerCompat = false`) |
| `/var/run/docker.sock` compat | Disabled (`dockerSocket.enable = false`) |
| Privileged containers | Not required / not granted by the platform |
| LAN firewall | Unchanged — Postgres/Redis bind guest loopback |

Compose provider is pinned to **`podman-compose` 1.6.0** from `nixpkgs-unstable` because
guest stable (`nixos-26.05`) only has 1.5.0, which cannot run:

```bash
podman compose up -d --wait
```

Determinism: `containers.conf` `engine.compose_providers` and the runner service
`PODMAN_COMPOSE_PROVIDER` both point at the unstable-pinned binary so discovery cannot
prefer a stray `docker-compose`.

Supported smoke:

```bash
podman info
podman compose version
podman compose -p ci-runner-e2e -f compose.yaml up -d --wait   # healthchecked postgres+redis on 127.0.0.1
podman compose -p ci-runner-e2e -f compose.yaml down -v          # removes project containers + named volumes
```

Fixtures (`fixtures/ci-runner-e2e/`) use project-local named volumes (`pgdata`, `redisdata`)
and assert those volumes are gone after `down -v`. Smoke scripts install EXIT traps that
attempt project-scoped `down -v` whenever the explicit volume-removal proof has not
completed — including when `up -d --wait` itself fails after partially creating resources.
Cleanup errors are ignored so they never mask the original failure. See
`podman-failure-cleanup-smoke.sh` for the controlled failure-path proof.

## Playwright Chromium support

Contract:

| Owner | Responsibility |
|-------|----------------|
| Consuming repository | `@playwright/test` version, Chromium revision, test config |
| Runner guest | OS runtime libraries via `programs.nix-ld.libraries` + basic fonts |

Supported model:

```text
Shopforge @playwright/test
  → playwright install chromium          # NOT --with-deps
  → Playwright-managed Chromium binary
  → nix-ld + guest shared libraries
```

The platform smoke fixture defaults to an explicit current stable pin
(`PLAYWRIGHT_VERSION=1.62.1` as of the 2026-08-10 correction pass; overridable) and runs
`npx playwright install chromium` without `--with-deps`. Consuming apps may choose their
own `@playwright/test` version; the guest only supplies the Chromium runtime library set.

Do **not** use `playwright install --with-deps` as the NixOS dependency mechanism. Do **not**
treat NixOS `chromium` as the primary browser executable unless the Playwright-managed path
proves unworkable.

Chromium runtime libraries added for headless launch (Playwright Chromium nativeDeps families):
ALSA, ATK, AT-SPI, Cairo, CUPS, DBus, DRM, GBM/Mesa/libGL, GLib, GTK3, NSPR, NSS, Pango,
X11/XCB/Xext/Xfixes/Xrandr/Xcomposite/Xdamage/xshmfence, `libxkbcommon`, Fontconfig,
Freetype, plus Liberation/DejaVu fonts.

**Sandbox tradeoff (Option A):** the root runner may result in Chromium running without its
internal sandbox. This is accepted for the trusted, one-job, throwaway guest. Do not add
extra `--no-sandbox` flags unless a real Playwright launcher requires them.

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
sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2
# optional GitHub regression (separate harness repo; not the production App):
# sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2 \
#   --github-repo tomuradjosip/nixos-ci-runner-validation
sudo ci-runnerctl install-base result/ci-runner-base.qcow2
sudo ci-runnerctl recycle-idle
```

Or: `sudo ci-runnerctl build-hint` prints the same sequence.

### Maintenance lifecycle

Human-controlled source changes (Git stays authoritative over flake inputs):

1. Update a flake input in `flake.nix`/`flake.lock` and **commit** it:
   - `nixpkgs-unstable` → newer `github-runner` (freshness monitor flags this), or
   - `nixpkgs-guest` → newer supported stable NixOS.
2. Build a candidate base image: `nix build .#ci-runner-guest-image -L`.
3. Validate with `validate-candidate` (never touches production idle pool / `install-base` /
   `current.qcow2`) — see [Validating a candidate image](#validating-a-candidate-image).

Operational install/recycle (once the candidate passes):

4. `sudo ci-runnerctl install-base <candidate.qcow2>` — atomic `base/current.qcow2` swap for
   **future** guests; busy guests keep their pinned overlay backing file.
5. `sudo ci-runnerctl recycle-idle` — destroy idle guests only, then reconcile replacements
   from the new base.
6. Verify new idle runners register and are `Listening for Jobs` (`ci-runnerctl status`).
7. Keep the previous base under `/data/ci/base/` for rollback; prune older unreferenced
   bases later once no overlays reference them.

> `ci-runner-reaper.service` is configured with `restartIfChanged = false` /
> `stopIfChanged = false` so a `nixos-rebuild switch` that only changes the provisioner
> package path does **not** re-run fail-closed `reap-boot` and destroy the warm spare.
> Real boots still run `reap-boot` once via `wantedBy = multi-user.target`.

## Validating a candidate image

Validate a candidate **before** `install-base`, without disturbing the production idle pool.

```bash
sudo ci-runnerctl validate-candidate <qcow2> [--timeout N] [--github-repo OWNER/REPO]
```

| Mode | Behaviour |
|------|-----------|
| Default (no `--github-repo`) | Dummy isolation: HTTPS/DNS/LAN/SSH/port probes, `ci-candidate-*` domain, trap cleanup, retain serial log. Never touches production spare, `install-base`, or `current.qcow2`. |
| `--probe-url URL` | Optional (repeatable). Runs `curl --fail` with normal TLS against each URL inside the disposable guest. Defaults to `services.ciRunner.validationUrls` when omitted. |
| `--github-repo OWNER/REPO` | Explicit GitHub validation. Registration token from `CI_RUNNER_REG_TOKEN` or `gh api` — **not** the production GitHub App (keeps validation harness auth separate). Waits for guest poweroff up to `--timeout` (default 240s). |

Probe an approved internal dependency without editing scripts:

```bash
sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2 \
  --probe-url https://verdaccio.iktstudio.com/
```

**Infrastructure regression harness (keep small / non-application).**
[`tomuradjosip/nixos-ci-runner-validation`](https://github.com/tomuradjosip/nixos-ci-runner-validation)
is the retained harness (not a consuming app repo):

| Workflow | Purpose |
|----------|---------|
| `node-validation.yml` | Single-runner Node / nix-ld compatibility |
| `pool-concurrency.yml` | Elastic pool: 3 overlapping lightweight jobs → scale / saturate / drain |
| `e2e-platform-smoke.yml` | Podman compose + Playwright Chromium combined smoke (`fixtures/ci-runner-e2e/`; `workflow_dispatch` only) |

Candidate Node check:

```bash
REPO=tomuradjosip/nixos-ci-runner-validation
sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2 \
  --github-repo "$REPO" --timeout 600
# once serial shows Listening for Jobs:
gh workflow run node-validation.yml -R "$REPO" --ref main
gh run watch -R "$REPO"
```

Podman / Playwright / combined platform smoke (after fixtures are vendored into the harness,
or checked out from this repo inside the job):

```bash
# Inside a candidate GitHub Actions job (runs-on nixos-ephemeral-ci):
bash fixtures/ci-runner-e2e/podman-smoke.sh
bash fixtures/ci-runner-e2e/playwright-smoke.sh
bash fixtures/ci-runner-e2e/combined-smoke.sh
```

Capture resource measurements from the combined job (`free -m`, `df`, Playwright cache size,
`podman system df`, overlay growth). **Do not** change guest RAM/vCPU/`maxGuests` automatically
if 4 GiB proves tight — report measurements for a human decision.
Elastic pool concurrency (temporarily point `secrets.ciRunner.githubRepo` at the harness,
`nixos-rebuild switch --impure`, `recycle-idle`; restore the consuming-app repo afterward).
If the GitHub App installation does not include the harness repo, the provisioner falls
back to host `gh` via `runuser` for list/register (App remains preferred when installed):

```bash
REPO=tomuradjosip/nixos-ci-runner-validation
sudo ci-runnerctl status   # expect idle=1 total=1 max=3
gh workflow run pool-concurrency.yml -R "$REPO" --ref main
# observe: busy/idle/total → saturate at 3 → drain back to idle=1
```

`validate-candidate` cleans up the `ci-candidate-*` guest on exit and prints whether the
production domain set was undisturbed. Serial log is retained under `/data/ci/logs/`.
See the [validation report](ci-runner-validation.md#elastic-pool-end-to-end-validation) for
the accepted live evidence.

## Operations

```bash
sudo ci-runnerctl status
sudo ci-runnerctl metrics
sudo ci-runnerctl freshness
sudo ci-runnerctl github-check
sudo ci-runnerctl reap
sudo ci-runnerctl reap-boot
sudo ci-runnerctl reconcile
sudo ci-runnerctl provision [ci|agent]
sudo ci-runnerctl dummy
sudo ci-runnerctl validate-candidate <qcow2> [--pool ci|agent] [--timeout N] [--github-repo OWNER/REPO] [--probe-url URL] [--allow-capacity-overcommit]
sudo ci-runnerctl install-base <qcow2>
sudo ci-runnerctl recycle-idle [ci|agent]
sudo ci-runnerctl build-hint
sudo ci-runnerctl destroy <domain>    # any managed prod/candidate prefix
sudo ci-runnerctl destroy-all         # all production prefixes (never candidates)
journalctl -u ci-runner-provisioner -u ci-runner-reaper -u ci-runner-freshness -t ci-runnerctl -f
virsh list --all
virsh net-info ci-net
```

`status` prints **host capacity** plus a block per pool (CI and agent). Metrics include legacy `ci_runner_*` gauges plus labelled `runner_pool_*{pool=…}` and `runner_host_*`.

### Troubleshooting internal HTTPS from CI

Distinguish failure layers:

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| Name does not resolve | Missing `internalDnsHosts` / guest not using CI DNS | From guest: `host verdaccio.iktstudio.com`; on host: `virsh net-dumpxml ci-net` `<dns>` section; guest `resolv.conf` should list `192.168.67.1` |
| Resolves, TCP times out / rejected | Missing or wrong `hostAllowTcp` / `internalAllowTcp` | `sudo iptables -L ci-runner-in -n -v`; `sudo iptables -L ci-runner-fwd -n -v` |
| TCP works, TLS fails | Cert / SNI / Traefik | From guest: `curl -v https://verdaccio.iktstudio.com/` (no `-k`); confirm Traefik cert covers the name |
| TLS works, HTTP error | Verdaccio / Traefik routing | Inspect Traefik/Verdaccio logs; host-side `curl -fsS https://verdaccio.iktstudio.com/` |

```text
DNS fails        → ci-net dnsmasq / internalDnsHosts
DNS ok, TCP fails → INPUT (hostAllowTcp) or FORWARD (internalAllowTcp)
TCP ok, TLS fails → certificate / SNI / Traefik
TLS ok, HTTP fails → Homepage / Traefik router
```

### `status` output

`ci-runnerctl status` prints a capacity block and per-guest lines:

```text
capacity:
  desired idle: …
  maximum:      …
  total:        …
  idle:         …
  busy:         …
  provisioning: …
  uncertain:    …
  saturated:    …
  github_ok:    …

guests:
  <ci-ephemeral-…>  <state>  base=<BASE_ID>
      overlay=…
      serial=…

candidates (ignored by production pool):   # only if any
  <ci-candidate-…>  libvirt=…
      serial=…
```

### Metrics (`ci_runner.prom`)

Written to `/var/lib/node_exporter_textfile/ci_runner.prom` from the last pool plan:

| Metric | Semantics |
|--------|-----------|
| `ci_runner_idle` | Healthy online managed runners with `busy=false` (GitHub-authoritative) |
| `ci_runner_busy` | Healthy online managed runners with `busy=true` |
| `ci_runner_provisioning` | Local running guests not yet online on GitHub (within grace) |
| `ci_runner_uncertain` | Running managed guests that cannot be safely classified |
| `ci_runner_total` | Managed production guests counting toward `maxGuests` after planned destroys |
| `ci_runner_max_guests` | Configured hard cap |
| `ci_runner_desired_idle` | Configured desired idle capacity |
| `ci_runner_saturated` | `1` when `idle==0` and `total>=maxGuests` (at capacity; behaving correctly) |
| `ci_runner_github_ok` | `1` if the last pool plan successfully queried GitHub runner state |
| `ci_runner_clean_capacity` | Legacy alias of `ci_runner_idle` |
| `ci_runner_guest_active` | Legacy: `1` if any managed production guest exists |
| `ci_runner_provision_success_timestamp` | Unix time of last successful provision |
| `ci_runner_provision_failures_total` | Provision failures |
| `ci_runner_teardown_failures_total` | Teardown failures |
| `ci_runner_orphan_cleanup_total` | Orphan resources cleaned |
| `ci_runner_overlay_bytes` | Bytes used by CI overlay disks |

Runner-freshness metrics are written separately to `ci_runner_freshness.prom` (see
[Runner freshness monitoring](#runner-freshness-monitoring)).

### Host reboot

On boot: libvirt network → reaper destroys any `ci-ephemeral-*` leftovers → provisioner
restores idle capacity when GitHub is enabled. CI guests are never autostarted.
`ci-candidate-*` guests are never touched by the production reaper.

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
| Pool plan snapshot | `sudo cat /data/ci/state/pool.json` |

The guest has **no SSH** (serial console only, by design). All guest diagnostics come from the
serial log; job stdout/stderr is also visible in the GitHub Actions run UI.

**Runner won't register / picks up no jobs**
- `Current runner version` in the serial log must be **≥ 2.329.0** and within **30 days** of
  the latest release (`ci-runnerctl freshness` → `update_available`). If behind, bump
  `nixpkgs-unstable`, rebuild, `validate-candidate`, `install-base`, `recycle-idle`.
- Job stuck "queued": confirm the workflow `runs-on` labels match `nixos-ephemeral-ci,self-hosted,Linux,X64`.
- `ci_runner_github_ok 0` / `saturated 1`: check App credentials and whether the pool is at `maxGuests` with no idle.

**Downloaded binary fails to run (ELF / loader issues)** — the most likely NixOS-specific class:
- Symptoms: `No such file or directory` when executing a downloaded binary that clearly
  exists, `cannot execute: required file not found`, or `error while loading shared libraries`.
- These mean the binary's hardcoded interpreter (`/lib64/ld-linux-x86-64.so.2`) or a shared
  library isn't resolvable. This platform relies on `programs.nix-ld` (guest) + `NIX_LD` /
  `NIX_LD_LIBRARY_PATH` exported to the runner service. Verify inside a job:
  `ls -l /lib64/ld-linux-x86-64.so.2` (should point at `…-nix-ld-…/libexec/nix-ld`) and
  `echo "$NIX_LD $NIX_LD_LIBRARY_PATH"`.
- Fix path: if a *specific* library is missing (`libfoo.so.N`) beyond the Chromium set already
  declared for Playwright, add that package to `programs.nix-ld.libraries` in
  `modules/ci-runner-guest.nix` — the **smallest** addition that resolves it, then rebuild +
  validate. Do not install a desktop environment to paper over missing `.so` files.

**`<tool>: command not found` in a job step**
- The job PATH is the `ci-runner-lifecycle` service `path` in `modules/ci-runner-guest.nix`
  (plus whatever `setup-*` actions prepend). If a *generic* Linux CI utility is missing, add
  its package there (this is how `tar`/`gzip`/… were added). Application toolchains are **not**
  added here — repositories install those via `actions/setup-*`.

**Guest didn't power off / overlay left behind**
- `uncertain guest == destroy`: `sudo ci-runnerctl destroy <ci-ephemeral-…>` (prefix-guarded)
  or `sudo ci-runnerctl reap` (soft, leaves running guests). `ci_runner_teardown_failures_total`
  and `ci_runner_orphan_cleanup_total` track these.

**Candidate validation** — use `validate-candidate` (see
[Validating a candidate image](#validating-a-candidate-image)); domains are `ci-candidate-*`
so the production reaper/reconciler ignore them.

## Limitations (by design)

- No `workflow_job` webhooks, no ARC, no Kubernetes, no queue-depth scaling — gradual
  burst ramp-up via 30s polling only.
- `maxGuests = 10` is an architectural ceiling, **not** live-safe at 4 GiB/guest on the
  current host without right-sizing; live default is `3`.
- Host control plane remains on `nixos-25.05`; only the disposable guest tracks supported stable.
- Docker Engine is not supplied in the guest; rootful Podman is guest-local only (no host socket).
- Guest RAM/vCPU remain 4096 MiB / 2 vCPU and `maxGuests = 3` until combined E2E evidence
  justifies a human sizing decision.

## Failure policy

`uncertain guest == contaminated guest == destroy`. Writable overlays are never reset and reused for another job.
