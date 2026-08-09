#!@bash@
# ci-runnerctl — host control plane for the ephemeral GitHub Actions runner pool.
# Placeholders of the form @name@ are substituted by packages/ci-runner-provisioner.nix.
set -euo pipefail

DATA_DIR=@dataDir@
NETWORK=@networkName@
BRIDGE=@bridgeName@
PREFIX=@domainPrefix@
CANDIDATE_PREFIX=@candidatePrefix@
LABEL=@runnerLabel@
RUNNER_VERSION=@runnerVersion@
DESIRED=@desiredIdleCapacity@
MAX_GUESTS=@maxGuests@
MEM=@guestMemoryMiB@
VCPUS=@guestVcpus@
LAN_PROBE=@lanProbeTarget@
GH_ENABLE=@githubEnable@
GH_OWNER=@githubOwner@
GH_REPO=@githubRepo@
GH_APP_ID=@githubAppId@
GH_INST_ID=@githubInstallationId@
GH_KEY=@githubPrivateKeyFile@
TEXTFILE_DIR=@textfileDir@
PROVISIONING_GRACE_SEC=@provisioningGraceSec@
BASE_LINK="$DATA_DIR/base/current.qcow2"
STATE_DIR="$DATA_DIR/state"
GUEST_STATE_DIR="$STATE_DIR/guests"
LOCK_FILE="$STATE_DIR/provision.lock"
STATUS_FILE="$STATE_DIR/status.env"
POOL_FILE="$STATE_DIR/pool.json"
METRICS_FILE="$TEXTFILE_DIR/ci_runner.prom"
FRESHNESS_FILE="$TEXTFILE_DIR/ci_runner_freshness.prom"
TOKEN_CACHE="$STATE_DIR/github_installation_token"
TOKEN_CACHE_EXP="$STATE_DIR/github_installation_token.exp"
POOL_BIN=@poolBin@
GH_APP_TOKEN_BIN=@ghAppTokenBin@

export PATH=@path@:$PATH

log() { echo "ci-runnerctl: $*" >&2; logger -t ci-runnerctl "$*" 2>/dev/null || true; }

ensure_dirs() {
  mkdir -p "$DATA_DIR/base" "$DATA_DIR/overlays" "$DATA_DIR/seeds" "$DATA_DIR/state" \
           "$DATA_DIR/logs" "$GUEST_STATE_DIR"
  chmod 0750 "$DATA_DIR" 2>/dev/null || true
  chmod 0700 "$DATA_DIR/overlays" "$DATA_DIR/seeds" "$DATA_DIR/state" "$GUEST_STATE_DIR" 2>/dev/null || true
}

with_lock() {
  ensure_dirs
  exec 9>"$LOCK_FILE"
  if ! flock -w 120 9; then
    log "timed out waiting for $LOCK_FILE"
    return 75
  fi
  "$@"
}

bump_counter() {
  local file="$1"
  local cur=0
  [[ -f "$file" ]] && cur=$(cat "$file")
  echo $((cur + 1)) >"$file"
}

guest_state_path() { echo "$GUEST_STATE_DIR/${1}.env"; }

write_guest_state() {
  local name="$1"
  shift
  local path
  path=$(guest_state_path "$name")
  {
    echo "NAME=$name"
    echo "UPDATED_AT=$(date -Is)"
    for kv in "$@"; do
      echo "$kv"
    done
  } >"$path.tmp"
  mv -f "$path.tmp" "$path"
}

read_guest_var() {
  local name="$1" key="$2" path
  path=$(guest_state_path "$name")
  if [[ -f "$path" ]]; then
    # shellcheck disable=SC1090
    source "$path"
    eval "echo \"\${$key-}\""
  fi
}

clear_guest_state() {
  rm -f "$(guest_state_path "$1")"
}

write_status() {
  # Aggregate summary for operators / legacy consumers. Per-guest truth lives in guests/*.env.
  local state="$1"
  shift
  {
    echo "STATE=$state"
    echo "UPDATED_AT=$(date -Is)"
    echo "DESIRED_IDLE=$DESIRED"
    echo "MAX_GUESTS=$MAX_GUESTS"
    for kv in "$@"; do
      echo "$kv"
    done
  } >"$STATUS_FILE.tmp"
  mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

require_base() {
  if [[ ! -e "$BASE_LINK" ]]; then
    log "missing base image link $BASE_LINK — run: ci-runnerctl install-base <qcow2>"
    return 1
  fi
}

resolve_base() {
  readlink -f "$BASE_LINK"
}

base_sha256() {
  # Prefer a sidecar hash written by install-base (avoids hashing ~800MB on every provision).
  local path="$1"
  if [[ -f "${path}.sha256" ]]; then
    awk '{print $1}' "${path}.sha256"
    return 0
  fi
  sha256sum "$path" | awk '{print $1}'
}

base_identity() {
  # Immutable generation identity for a base qcow2 (path + sha256 prefix).
  local path="$1"
  local sum
  sum=$(base_sha256 "$path")
  echo "BASE_PATH=$path"
  echo "BASE_SHA256=$sum"
  echo "BASE_ID=${sum:0:16}"
}

list_prefixed_domains() {
  local pfx="$1"
  virsh list --all --name 2>/dev/null | grep "^${pfx}" || true
}

list_ci_domains() { list_prefixed_domains "$PREFIX"; }
list_candidate_domains() { list_prefixed_domains "$CANDIDATE_PREFIX"; }

guest_count() {
  list_ci_domains | grep -c . || true
}

destroy_guest() {
  local name="$1"
  case "$name" in
    "${PREFIX}"*|"${CANDIDATE_PREFIX}"*) ;;
    *)
      log "refusing to destroy non-managed domain: $name"
      return 2
      ;;
  esac
  log "destroying guest $name"
  virsh destroy "$name" 2>/dev/null || true
  virsh undefine "$name" --remove-all-storage 2>/dev/null \
    || virsh undefine "$name" 2>/dev/null \
    || true
  rm -f "$DATA_DIR/overlays/${name}.qcow2" \
        "$DATA_DIR/seeds/${name}.iso" 2>/dev/null || true
  rm -rf "$DATA_DIR/seeds/${name}.dir" 2>/dev/null || true
  clear_guest_state "$name"
}

reap_orphans() {
  # mode=boot → destroy every production CI guest (post-reboot / fail-closed)
  # mode=soft → destroy only non-running production guests + orphan disks
  # Candidate (ci-candidate-*) resources are NEVER touched by production reaping.
  local mode="${1:-soft}"
  log "reaping stale CI resources mode=$mode prefix=$PREFIX"
  local cleaned=0 d state
  for d in $(list_ci_domains); do
    state=$(virsh domstate "$d" 2>/dev/null | tr -d '[:space:]' || echo missing)
    if [[ "$mode" == "boot" ]]; then
      log "reaper(boot): removing domain $d (state=$state)"
      destroy_guest "$d"
      cleaned=$((cleaned + 1))
    else
      case "$state" in
        running)
          log "reaper(soft): leaving running guest $d"
          ;;
        *)
          log "reaper(soft): removing non-running domain $d (state=$state)"
          destroy_guest "$d"
          cleaned=$((cleaned + 1))
          ;;
      esac
    fi
  done
  local f base
  if [[ -d "$DATA_DIR/overlays" ]]; then
    for f in "$DATA_DIR/overlays"/${PREFIX}*.qcow2; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f" .qcow2)
      if ! virsh dominfo "$base" >/dev/null 2>&1; then
        log "reaper: removing orphan overlay $f"
        rm -f "$f"
        cleaned=$((cleaned + 1))
      fi
    done
  fi
  if [[ -d "$DATA_DIR/seeds" ]]; then
    for f in "$DATA_DIR/seeds"/${PREFIX}*.iso; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f" .iso)
      if ! virsh dominfo "$base" >/dev/null 2>&1; then
        log "reaper: removing orphan seed $f"
        rm -f "$f"
        cleaned=$((cleaned + 1))
      fi
    done
    for f in "$DATA_DIR/seeds"/${PREFIX}*.dir; do
      [[ -d "$f" ]] || continue
      base=$(basename "$f" .dir)
      if ! virsh dominfo "$base" >/dev/null 2>&1; then
        log "reaper: removing orphan seed dir $f"
        rm -rf "$f"
        cleaned=$((cleaned + 1))
      fi
    done
  fi
  # Orphan per-guest state files
  if [[ -d "$GUEST_STATE_DIR" ]]; then
    for f in "$GUEST_STATE_DIR"/${PREFIX}*.env; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f" .env)
      if ! virsh dominfo "$base" >/dev/null 2>&1; then
        log "reaper: removing orphan guest state $f"
        rm -f "$f"
        cleaned=$((cleaned + 1))
      fi
    done
  fi
  if [[ "$cleaned" -gt 0 ]]; then
    local cur=0
    [[ -f "$STATE_DIR/orphan_cleanup" ]] && cur=$(cat "$STATE_DIR/orphan_cleanup")
    echo $((cur + cleaned)) >"$STATE_DIR/orphan_cleanup"
  fi
  write_metrics
  log "reaper done cleaned=$cleaned"
}

make_seed_iso() {
  local name="$1"
  local mode="$2"
  local seed_dir="$DATA_DIR/seeds/${name}.dir"
  local seed_iso="$DATA_DIR/seeds/${name}.iso"
  mkdir -p "$DATA_DIR/seeds"
  rm -rf "$seed_dir"
  mkdir -p "$seed_dir"
  {
    echo "MODE=$mode"
    echo "LAN_PROBE_TARGET=$LAN_PROBE"
    if [[ "$mode" == "runner" ]]; then
      echo "REPO_URL=$3"
      echo "REGISTRATION_TOKEN=$4"
      echo "RUNNER_NAME=$name"
      echo "RUNNER_LABELS=$LABEL,self-hosted,Linux,X64"
    fi
  } >"$seed_dir/ci-seed.env"
  chmod 0600 "$seed_dir/ci-seed.env"
  xorriso -as mkisofs -V CI_SEED -o "$seed_iso" -J -r "$seed_dir" >/dev/null 2>&1
  # Drop plaintext token from the seed dir tree; ISO remains until guest destroy.
  rm -f "$seed_dir/ci-seed.env"
  echo "$seed_iso"
}

create_overlay_from() {
  local name="$1"
  local backing="$2"
  local overlay="$DATA_DIR/overlays/${name}.qcow2"
  mkdir -p "$DATA_DIR/overlays"
  rm -f "$overlay"
  # Pin to the immutable resolved base path so current.qcow2 can rotate safely.
  qemu-img create -f qcow2 -b "$backing" -F qcow2 "$overlay" >/dev/null
  echo "$overlay"
}

define_and_start() {
  local name="$1"
  local overlay="$2"
  local seed_iso="$3"
  local serial_log="$DATA_DIR/logs/${name}.serial.log"
  mkdir -p "$DATA_DIR/logs"
  : >"$serial_log"
  virsh destroy "$name" 2>/dev/null || true
  virsh undefine "$name" 2>/dev/null || true
  virt-install \
    --connect qemu:///system \
    --name "$name" \
    --memory "$MEM" \
    --vcpus "$VCPUS" \
    --cpu host-model \
    --import \
    --disk "path=$overlay,format=qcow2,bus=virtio" \
    --disk "path=$seed_iso,device=cdrom,bus=sata,readonly=on" \
    --network "network=$NETWORK,model=virtio" \
    --graphics none \
    --serial "file,path=$serial_log" \
    --console pty,target_type=serial \
    --os-variant generic \
    --noautoconsole \
    --wait 0
  virsh autostart --disable "$name" 2>/dev/null || true
  local state
  state=$(virsh domstate "$name" 2>/dev/null | tr -d '[:space:]' || echo missing)
  if [[ "$state" != "running" ]]; then
    log "guest $name not running after virt-install (state=$state)"
    return 1
  fi
  log "serial log: $serial_log"
}

# --- GitHub App auth (host-only; installation tokens expire in 1 hour per GitHub docs) ---

mint_installation_token_raw() {
  "$GH_APP_TOKEN_BIN" "$GH_APP_ID" "$GH_INST_ID" "$GH_KEY"
}

get_installation_token() {
  # Cache the installation access token securely on the host. GitHub documents a
  # 1-hour lifetime; refresh 5 minutes early. Never inject into guests.
  ensure_dirs
  local now exp token
  now=$(date +%s)
  if [[ -f "$TOKEN_CACHE" && -f "$TOKEN_CACHE_EXP" ]]; then
    exp=$(cat "$TOKEN_CACHE_EXP" 2>/dev/null || echo 0)
    if [[ "$exp" =~ ^[0-9]+$ ]] && [[ "$now" -lt "$exp" ]]; then
      cat "$TOKEN_CACHE"
      return 0
    fi
  fi
  token=$(mint_installation_token_raw) || return 1
  [[ -n "$token" ]] || return 1
  umask 077
  printf '%s' "$token" >"$TOKEN_CACHE.tmp"
  # Expire at now+55m (tokens last 1h per GitHub App docs).
  echo $((now + 55 * 60)) >"$TOKEN_CACHE_EXP.tmp"
  mv -f "$TOKEN_CACHE.tmp" "$TOKEN_CACHE"
  mv -f "$TOKEN_CACHE_EXP.tmp" "$TOKEN_CACHE_EXP"
  chmod 0600 "$TOKEN_CACHE" "$TOKEN_CACHE_EXP"
  printf '%s' "$token"
}

# Prefer the GitHub App for production repo API calls. When the App installation does
# not include the target repo (common for the retained validation harness), fall back
# to the invoking user's authenticated `gh` — same auth path as validate-candidate.
# Fail-closed behaviour is unchanged: if neither App nor gh can reach the API, callers
# treat GitHub as unavailable.
gh_api_user() {
  # Prefer explicit override, then sudo invoker, then a local user with gh auth
  # (systemd oneshots have neither SUDO_USER nor root gh credentials).
  local user="${CI_RUNNER_GH_USER:-${SUDO_USER:-}}"
  if [[ -z "$user" ]]; then
    local d
    for d in /home/*; do
      [[ -f "$d/.config/gh/hosts.yml" ]] || continue
      user=$(basename "$d")
      break
    done
  fi
  printf '%s' "$user"
}

gh_api_as_invoker() {
  # Usage: gh_api_as_invoker <gh api args...>
  # Use runuser (util-linux, on our PATH) rather than sudo: systemd oneshots do not
  # include sudo in PATH, so `sudo -u … gh` silently fails and root's unauthenticated
  # `gh` then makes GitHub look unavailable (fail-closed, no provisioning).
  local user
  user=$(gh_api_user)
  if [[ -n "$user" ]] && command -v gh >/dev/null 2>&1; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$user" -- gh api "$@"
    elif command -v sudo >/dev/null 2>&1; then
      sudo -u "$user" gh api "$@"
    else
      return 1
    fi
  elif command -v gh >/dev/null 2>&1; then
    gh api "$@"
  else
    return 1
  fi
}

fetch_registration_token() {
  local owner="$1" repo="$2"
  local inst_token reg_json token
  if [[ -f "$GH_KEY" ]]; then
    if inst_token=$(get_installation_token 2>/dev/null); then
      if reg_json=$(curl -fsS -X POST \
        -H "Authorization: Bearer $inst_token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token" 2>/dev/null); then
        token=$(echo "$reg_json" | jq -r '.token // empty')
        if [[ -n "$token" ]]; then
          echo "$token"
          return 0
        fi
      fi
      log "App registration-token failed for ${owner}/${repo}; trying gh fallback"
    else
      log "failed to mint installation token; trying gh fallback"
    fi
  else
    log "missing GitHub App private key at $GH_KEY; trying gh fallback"
  fi
  token=$(gh_api_as_invoker -X POST "/repos/${owner}/${repo}/actions/runners/registration-token" -q .token) || {
    log "registration-token failed via App and gh (App needs repo access, or authenticate gh as admin)"
    return 1
  }
  [[ -n "$token" ]] || {
    log "registration-token response had no .token"
    return 1
  }
  echo "$token"
}

list_github_runners_json() {
  # Prints the .runners array JSON, or fails. Uses official
  # GET /repos/{owner}/{repo}/actions/runners (status + busy fields).
  local owner="$1" repo="$2"
  local inst_token body
  if [[ -f "$GH_KEY" ]]; then
    if inst_token=$(get_installation_token 2>/dev/null); then
      if body=$(curl -fsS \
        -H "Authorization: Bearer $inst_token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner}/${repo}/actions/runners" 2>/dev/null); then
        echo "$body" | jq -c '.runners // []'
        return 0
      fi
      log "App runners list failed for ${owner}/${repo}; trying gh fallback"
    fi
  fi
  body=$(gh_api_as_invoker "/repos/${owner}/${repo}/actions/runners") || return 1
  echo "$body" | jq -c '.runners // []'
}

github_check() {
  echo "github.enable (baked): $GH_ENABLE (0=disabled, 1=enabled)"
  echo "owner/repo : $GH_OWNER/$GH_REPO"
  echo "appId      : $GH_APP_ID"
  echo "instId     : $GH_INST_ID"
  echo "keyFile    : $GH_KEY"
  if [[ -z "$GH_OWNER" || -z "$GH_REPO" || -z "$GH_APP_ID" || -z "$GH_INST_ID" ]]; then
    echo "FAIL: owner/repo/appId/installationId incomplete (see secrets.ciRunner)"
    return 1
  fi
  if [[ ! -f "$GH_KEY" ]]; then
    echo "FAIL: private key not found at $GH_KEY"
    return 1
  fi
  local perms
  perms=$(stat -c '%a' "$GH_KEY" 2>/dev/null || echo "?")
  echo "keyPerms   : $perms (expect 0400/0600, root-owned)"
  local inst_token
  if inst_token=$(get_installation_token 2>/dev/null); then
    [[ -n "$inst_token" ]] || { echo "FAIL: empty installation token"; return 1; }
    echo "OK  : minted installation access token"
  else
    echo "WARN: App installation token failed (App may not include $GH_OWNER/$GH_REPO); will try gh fallback for runner list/reg-token"
  fi
  local runners n token
  # Prefer unified list helper (App then gh fallback) so harness targeting works.
  runners=$(list_github_runners_json "$GH_OWNER" "$GH_REPO") || {
    echo "FAIL: cannot list repo runners via App or gh (App needs repo access, or authenticate gh as admin)"
    return 1
  }
  n=$(echo "$runners" | jq -r 'length')
  echo "OK  : listed repo self-hosted runners (currently registered: $n)"
  echo "$runners" | jq -r '.[]? | "  - \(.name) status=\(.status) busy=\(.busy)"'
  token=$(fetch_registration_token "$GH_OWNER" "$GH_REPO") || {
    echo "FAIL: cannot mint registration-token via App or gh"
    return 1
  }
  if [[ -n "$token" ]]; then
    echo "OK  : minted a registration token (discarded; NO runner was registered)"
  else
    echo "FAIL: registration-token response had no token"
    return 1
  fi
  echo "PASS: credentials valid — safe to provision a runner guest."
}

delete_stale_github_runners() {
  if [[ "$GH_ENABLE" != "1" ]]; then
    return 0
  fi
  local runners
  runners=$(list_github_runners_json "$GH_OWNER" "$GH_REPO" 2>/dev/null) || return 0
  [[ -n "$runners" ]] || return 0
  echo "$runners" | jq -r --arg p "$PREFIX" \
    '.[]? | select(.name|startswith($p)) | "\(.id) \(.name) \(.status)"' \
    | while read -r id name status; do
        if [[ "$status" == "offline" ]]; then
          log "deleting stale GitHub runner $name ($id)"
          # Prefer App DELETE when installed on the repo; else gh (harness targeting).
          local inst_token
          if inst_token=$(get_installation_token 2>/dev/null); then
            curl -fsS -X DELETE \
              -H "Authorization: Bearer $inst_token" \
              -H "Accept: application/vnd.github+json" \
              -H "X-GitHub-Api-Version: 2022-11-28" \
              "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/actions/runners/$id" \
              >/dev/null 2>&1 && continue
          fi
          gh_api_as_invoker -X DELETE "/repos/${GH_OWNER}/${GH_REPO}/actions/runners/$id" \
            >/dev/null 2>&1 || true
        fi
      done
}

# --- Snapshot + pool plan -------------------------------------------------

collect_domain_snapshot_json() {
  # Emit JSON array of {name, libvirt_state, created_at} for ALL libvirt domains
  # (planner filters by prefix). created_at comes from per-guest state when present.
  local d state created arr="["
  local first=1
  for d in $(virsh list --all --name 2>/dev/null); do
    [[ -n "$d" ]] || continue
    state=$(virsh domstate "$d" 2>/dev/null || echo missing)
    created=$(read_guest_var "$d" CREATED_AT_UNIX)
    [[ -n "$created" ]] || created=0
    if [[ "$first" -eq 1 ]]; then first=0; else arr+=","; fi
    arr+=$(jq -nc --arg n "$d" --arg s "$state" --argjson c "$created" \
      '{name:$n, libvirt_state:$s, created_at:$c}')
  done
  arr+="]"
  echo "$arr"
}

plan_pool() {
  # Build snapshot, invoke pure planner, write POOL_FILE, print plan JSON on stdout.
  local github_ok=false runners='[]' domains now snap plan
  now=$(date +%s)
  domains=$(collect_domain_snapshot_json)
  if [[ "$GH_ENABLE" == "1" ]]; then
    if runners=$(list_github_runners_json "$GH_OWNER" "$GH_REPO" 2>/dev/null); then
      github_ok=true
    else
      log "GitHub API unavailable — fail-closed (no overprovision, retain running guests)"
      runners='[]'
      github_ok=false
    fi
  else
    log "GitHub disabled; pool plan will not provision"
    github_ok=false
  fi
  # Normalize runners to the fields the planner needs.
  runners=$(echo "$runners" | jq -c '[.[] | {name, status, busy: (.busy // false)}]')
  snap=$(jq -nc \
    --argjson domains "$domains" \
    --argjson runners "$runners" \
    --argjson github_ok "$github_ok" \
    --argjson now "$now" \
    --arg prefix "$PREFIX" \
    --arg cprefix "$CANDIDATE_PREFIX" \
    --argjson desired "$DESIRED" \
    --argjson maxg "$MAX_GUESTS" \
    --argjson grace "$PROVISIONING_GRACE_SEC" \
    '{
      config: {
        prefix: $prefix,
        candidate_prefix: $cprefix,
        desired_idle: $desired,
        max_guests: $maxg,
        provisioning_grace_sec: $grace
      },
      now: $now,
      github_ok: $github_ok,
      domains: $domains,
      github_runners: $runners
    }')
  plan=$(echo "$snap" | "$POOL_BIN" plan)
  echo "$plan" >"$POOL_FILE.tmp"
  mv -f "$POOL_FILE.tmp" "$POOL_FILE"
  echo "$plan"
}

write_metrics() {
  mkdir -p "$TEXTFILE_DIR"
  local idle=0 busy=0 provisioning=0 uncertain=0 total=0 saturated=0 github_ok=0
  local overlay_bytes=0
  if [[ -f "$POOL_FILE" ]]; then
    idle=$(jq -r '.counts.idle // 0' "$POOL_FILE")
    busy=$(jq -r '.counts.busy // 0' "$POOL_FILE")
    provisioning=$(jq -r '.counts.provisioning // 0' "$POOL_FILE")
    uncertain=$(jq -r '.counts.uncertain // 0' "$POOL_FILE")
    total=$(jq -r '.counts.total // 0' "$POOL_FILE")
    saturated=$(jq -r 'if .saturated then 1 else 0 end' "$POOL_FILE")
    github_ok=$(jq -r 'if .github_ok then 1 else 0 end' "$POOL_FILE")
  else
    # Fallback: count live production domains only.
    total=$(guest_count)
  fi
  if [[ -d "$DATA_DIR/overlays" ]]; then
    overlay_bytes=$(du -sb "$DATA_DIR/overlays" 2>/dev/null | awk '{print $1}')
  fi
  local provision_ts=0 provision_fail=0 teardown_fail=0 orphan_clean=0
  [[ -f "$STATE_DIR/provision_success_ts" ]] && provision_ts=$(cat "$STATE_DIR/provision_success_ts")
  [[ -f "$STATE_DIR/provision_failures" ]] && provision_fail=$(cat "$STATE_DIR/provision_failures")
  [[ -f "$STATE_DIR/teardown_failures" ]] && teardown_fail=$(cat "$STATE_DIR/teardown_failures")
  [[ -f "$STATE_DIR/orphan_cleanup" ]] && orphan_clean=$(cat "$STATE_DIR/orphan_cleanup")
  local tmp="$METRICS_FILE.$$.tmp"
  {
    echo '# HELP ci_runner_idle Healthy online managed runners with busy=false (GitHub-authoritative).'
    echo '# TYPE ci_runner_idle gauge'
    echo "ci_runner_idle $idle"
    echo '# HELP ci_runner_busy Healthy online managed runners with busy=true (GitHub-authoritative).'
    echo '# TYPE ci_runner_busy gauge'
    echo "ci_runner_busy $busy"
    echo '# HELP ci_runner_provisioning Local running guests not yet online on GitHub (within grace).'
    echo '# TYPE ci_runner_provisioning gauge'
    echo "ci_runner_provisioning $provisioning"
    echo '# HELP ci_runner_uncertain Running managed guests that cannot be safely classified.'
    echo '# TYPE ci_runner_uncertain gauge'
    echo "ci_runner_uncertain $uncertain"
    echo '# HELP ci_runner_total Managed production guest resources counting toward maxGuests (local libvirt-authoritative after reconcile destroys).'
    echo '# TYPE ci_runner_total gauge'
    echo "ci_runner_total $total"
    echo '# HELP ci_runner_max_guests Configured hard cap on managed production guests.'
    echo '# TYPE ci_runner_max_guests gauge'
    echo "ci_runner_max_guests $MAX_GUESTS"
    echo '# HELP ci_runner_desired_idle Configured desired idle capacity.'
    echo '# TYPE ci_runner_desired_idle gauge'
    echo "ci_runner_desired_idle $DESIRED"
    echo '# HELP ci_runner_saturated 1 when idle==0 and total>=maxGuests (platform at capacity, behaving correctly).'
    echo '# TYPE ci_runner_saturated gauge'
    echo "ci_runner_saturated $saturated"
    echo '# HELP ci_runner_github_ok 1 if the last pool plan successfully queried GitHub runner state.'
    echo '# TYPE ci_runner_github_ok gauge'
    echo "ci_runner_github_ok $github_ok"
    # Back-compat aliases
    echo '# HELP ci_runner_clean_capacity Alias of ci_runner_idle (legacy).'
    echo '# TYPE ci_runner_clean_capacity gauge'
    echo "ci_runner_clean_capacity $idle"
    echo '# HELP ci_runner_guest_active 1 if any managed production guest exists (legacy).'
    echo '# TYPE ci_runner_guest_active gauge'
    echo "ci_runner_guest_active $([[ "$total" -gt 0 ]] && echo 1 || echo 0)"
    echo '# HELP ci_runner_provision_success_timestamp Unix time of last successful provision'
    echo '# TYPE ci_runner_provision_success_timestamp gauge'
    echo "ci_runner_provision_success_timestamp $provision_ts"
    echo '# HELP ci_runner_provision_failures_total Provision failures'
    echo '# TYPE ci_runner_provision_failures_total counter'
    echo "ci_runner_provision_failures_total $provision_fail"
    echo '# HELP ci_runner_teardown_failures_total Teardown failures'
    echo '# TYPE ci_runner_teardown_failures_total counter'
    echo "ci_runner_teardown_failures_total $teardown_fail"
    echo '# HELP ci_runner_orphan_cleanup_total Orphan resources cleaned'
    echo '# TYPE ci_runner_orphan_cleanup_total counter'
    echo "ci_runner_orphan_cleanup_total $orphan_clean"
    echo '# HELP ci_runner_overlay_bytes Bytes used by CI overlay disks'
    echo '# TYPE ci_runner_overlay_bytes gauge'
    echo "ci_runner_overlay_bytes ${overlay_bytes:-0}"
  } >"$tmp"
  mv -f "$tmp" "$METRICS_FILE"
}

check_freshness() {
  mkdir -p "$TEXTFILE_DIR"
  local baked="$RUNNER_VERSION"
  local now latest published latest_ts ok update deadline_ts json
  now=$(date +%s)
  latest=""; published=""; latest_ts=0; ok=0; update=0; deadline_ts=0
  if json=$(curl -fsS --max-time 20 \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/actions/runner/releases/latest" 2>/dev/null); then
    latest=$(printf '%s' "$json" | jq -r '.tag_name // empty' | sed 's/^v//')
    published=$(printf '%s' "$json" | jq -r '.published_at // empty')
    if [[ -n "$latest" ]]; then
      ok=1
      if [[ -n "$published" ]]; then
        latest_ts=$(date -d "$published" +%s 2>/dev/null || echo 0)
      fi
      if [[ -n "$baked" && "$baked" != "$latest" ]]; then
        update=1
        if [[ "$latest_ts" -gt 0 ]]; then
          deadline_ts=$((latest_ts + 30 * 86400))
        fi
      fi
    fi
  fi
  local tmp="$FRESHNESS_FILE.$$.tmp"
  {
    echo '# HELP ci_runner_baked_version_info Runner version baked into the current guest image (version is a label).'
    echo '# TYPE ci_runner_baked_version_info gauge'
    echo "ci_runner_baked_version_info{version=\"${baked:-unknown}\"} 1"
    echo '# HELP ci_runner_latest_version_info Latest published GitHub Actions runner release (version is a label).'
    echo '# TYPE ci_runner_latest_version_info gauge'
    echo "ci_runner_latest_version_info{version=\"${latest:-unknown}\"} 1"
    echo '# HELP ci_runner_update_available 1 if the baked runner is behind the latest published release.'
    echo '# TYPE ci_runner_update_available gauge'
    echo "ci_runner_update_available $update"
    echo '# HELP ci_runner_latest_release_timestamp Unix time the latest runner release was published.'
    echo '# TYPE ci_runner_latest_release_timestamp gauge'
    echo "ci_runner_latest_release_timestamp $latest_ts"
    echo '# HELP ci_runner_update_deadline_timestamp Unix time GitHub stops queuing jobs to an un-updated runner (latest release + 30d); 0 when up to date or unknown.'
    echo '# TYPE ci_runner_update_deadline_timestamp gauge'
    echo "ci_runner_update_deadline_timestamp $deadline_ts"
    echo '# HELP ci_runner_freshness_check_timestamp Unix time of the last freshness check.'
    echo '# TYPE ci_runner_freshness_check_timestamp gauge'
    echo "ci_runner_freshness_check_timestamp $now"
    echo '# HELP ci_runner_freshness_check_success 1 if the last freshness check reached the GitHub releases API.'
    echo '# TYPE ci_runner_freshness_check_success gauge'
    echo "ci_runner_freshness_check_success $ok"
  } >"$tmp"
  mv -f "$tmp" "$FRESHNESS_FILE"
  echo "baked runner : ${baked:-unknown}"
  echo "latest runner: ${latest:-unknown} (check_success=$ok)"
  if [[ "$update" == "1" ]]; then
    local human="unknown"
    [[ "$deadline_ts" -gt 0 ]] && human=$(date -d "@$deadline_ts" -Is 2>/dev/null || echo unknown)
    echo "UPDATE AVAILABLE: bump nixpkgs-unstable, rebuild + validate + install-base. Deadline ~$human"
  else
    echo "up to date (or latest unknown; nothing to do)"
  fi
}

provision_one() {
  local mode="${1:-runner}"
  local owner="${2:-$GH_OWNER}"
  local repo="${3:-$GH_REPO}"
  local base_path="${4:-}"
  local name_prefix="${5:-$PREFIX}"

  if [[ -z "$base_path" ]]; then
    require_base
    base_path=$(resolve_base)
  fi
  [[ -f "$base_path" ]] || { log "base image not found: $base_path"; return 1; }

  if [[ "$name_prefix" == "$PREFIX" ]]; then
    local count
    count=$(guest_count)
    if [[ "$count" -ge "$MAX_GUESTS" ]]; then
      log "max guests reached ($count >= $MAX_GUESTS)"
      return 0
    fi
  fi

  local name overlay seed_iso token repo_url created
  name="${name_prefix}$(date +%Y%m%d%H%M%S)-$RANDOM"
  created=$(date +%s)
  log "provisioning $name mode=$mode base=$base_path"

  # Record identity before start so a crash mid-boot still has state for the planner.
  {
    echo "NAME=$name"
    echo "UPDATED_AT=$(date -Is)"
    echo "CREATED_AT_UNIX=$created"
    echo "MODE=$mode"
    base_identity "$base_path"
    echo "SERIAL_LOG=$DATA_DIR/logs/${name}.serial.log"
    echo "OVERLAY=$DATA_DIR/overlays/${name}.qcow2"
    echo "POOL_STATE=provisioning"
  } >"$(guest_state_path "$name")"

  overlay=$(create_overlay_from "$name" "$base_path")
  if [[ "$mode" == "runner" ]]; then
    token=$(fetch_registration_token "$owner" "$repo") || {
      bump_counter "$STATE_DIR/provision_failures"
      destroy_guest "$name"
      return 1
    }
    repo_url="https://github.com/${owner}/${repo}"
    seed_iso=$(make_seed_iso "$name" runner "$repo_url" "$token")
    unset token
  else
    seed_iso=$(make_seed_iso "$name" dummy)
  fi
  if ! define_and_start "$name" "$overlay" "$seed_iso"; then
    log "failed to start $name"
    bump_counter "$STATE_DIR/provision_failures"
    destroy_guest "$name"
    return 1
  fi
  date +%s >"$STATE_DIR/provision_success_ts"
  {
    echo "NAME=$name"
    echo "UPDATED_AT=$(date -Is)"
    echo "CREATED_AT_UNIX=$created"
    echo "MODE=$mode"
    base_identity "$base_path"
    echo "SERIAL_LOG=$DATA_DIR/logs/${name}.serial.log"
    echo "OVERLAY=$overlay"
    echo "POOL_STATE=provisioning"
  } >"$(guest_state_path "$name")"
  log "provisioned $name"
  echo "$name"
}

reconcile() {
  log "reconcile start desired_idle=$DESIRED max_guests=$MAX_GUESTS"
  ensure_dirs
  local plan destroy_list n_destroy i name to_prov github_ok
  plan=$(plan_pool)
  github_ok=$(echo "$plan" | jq -r 'if .github_ok then "true" else "false" end')
  log "pool: idle=$(echo "$plan" | jq -r '.counts.idle') busy=$(echo "$plan" | jq -r '.counts.busy') provisioning=$(echo "$plan" | jq -r '.counts.provisioning') total=$(echo "$plan" | jq -r '.counts.total') provision=$(echo "$plan" | jq -r '.provision') github_ok=$github_ok saturated=$(echo "$plan" | jq -r '.saturated')"

  # Apply safe destroys first (capacity reclaim).
  destroy_list=$(echo "$plan" | jq -r '.destroy[]?')
  for name in $destroy_list; do
    [[ -n "$name" ]] || continue
    log "reconcile: destroying $name (state=$(echo "$plan" | jq -r --arg n "$name" '.classify[$n]'))"
    destroy_guest "$name" || bump_counter "$STATE_DIR/teardown_failures"
  done

  if [[ "$GH_ENABLE" == "1" ]]; then
    delete_stale_github_runners || true
  fi

  # Re-plan after destroys so remainingCapacity is accurate, then provision under the same lock.
  plan=$(plan_pool)
  to_prov=$(echo "$plan" | jq -r '.provision // 0')
  if [[ "$GH_ENABLE" != "1" ]]; then
    log "GitHub disabled; not provisioning"
    to_prov=0
  fi
  i=0
  while [[ "$i" -lt "$to_prov" ]]; do
    log "reconcile: provisioning replacement ($((i + 1))/$to_prov)"
    provision_one runner || true
    i=$((i + 1))
  done

  plan=$(plan_pool)
  write_status pool \
    "IDLE=$(echo "$plan" | jq -r '.counts.idle')" \
    "BUSY=$(echo "$plan" | jq -r '.counts.busy')" \
    "PROVISIONING=$(echo "$plan" | jq -r '.counts.provisioning')" \
    "TOTAL=$(echo "$plan" | jq -r '.counts.total')" \
    "SATURATED=$(echo "$plan" | jq -r '.saturated')" \
    "GITHUB_OK=$(echo "$plan" | jq -r '.github_ok')"
  write_metrics
  log "reconcile done"
}

recycle_idle() {
  # Destroy only healthy idle production guests so they are replaced from the current base.
  # Busy guests are left alone to finish their jobs on their pinned overlay/base.
  log "recycle-idle start"
  local plan name
  plan=$(plan_pool)
  echo "$plan" | jq -r '.classify | to_entries[] | select(.value=="idle") | .key' \
    | while read -r name; do
        [[ -n "$name" ]] || continue
        log "recycle-idle: destroying idle guest $name"
        destroy_guest "$name" || bump_counter "$STATE_DIR/teardown_failures"
      done
  # Reconcile will restore desired idle capacity from the new base.
  reconcile
}

wait_guest_poweroff() {
  local name="$1"
  local timeout="${2:-240}"
  local i=0 state
  log "waiting for guest $name to shut down (timeout ${timeout}s)"
  while [[ $i -lt $timeout ]]; do
    if ! virsh dominfo "$name" >/dev/null 2>&1; then
      return 0
    fi
    state=$(virsh domstate "$name" 2>/dev/null | tr -d '[:space:]' || echo missing)
    if [[ "$state" == "missing" || "$state" == "shutoff" ]]; then
      return 0
    fi
    sleep 2
    i=$((i + 2))
  done
  return 1
}

print_status() {
  ensure_dirs
  local plan base_resolved
  base_resolved=$(readlink -f "$BASE_LINK" 2>/dev/null || echo missing)
  echo "DATA_DIR=$DATA_DIR"
  echo "BASE_LINK=$BASE_LINK -> $base_resolved"
  if [[ -f "$base_resolved" ]]; then
    echo "BASE_ID=$(sha256sum "$base_resolved" | awk '{print substr($1,1,16)}')"
  fi
  echo "NETWORK=$NETWORK BRIDGE=$BRIDGE"
  echo "GH_ENABLE=$GH_ENABLE  repo=${GH_OWNER}/${GH_REPO}"
  echo "PREFIX=$PREFIX  CANDIDATE_PREFIX=$CANDIDATE_PREFIX"
  # Refresh plan for operator view (under lock by caller when needed).
  plan=$(plan_pool 2>/dev/null || echo '{}')
  echo
  echo "capacity:"
  echo "  desired idle: $DESIRED"
  echo "  maximum:      $MAX_GUESTS"
  echo "  total:        $(echo "$plan" | jq -r '.counts.total // 0')"
  echo "  idle:         $(echo "$plan" | jq -r '.counts.idle // 0')"
  echo "  busy:         $(echo "$plan" | jq -r '.counts.busy // 0')"
  echo "  provisioning: $(echo "$plan" | jq -r '.counts.provisioning // 0')"
  echo "  uncertain:    $(echo "$plan" | jq -r '.counts.uncertain // 0')"
  echo "  saturated:    $(echo "$plan" | jq -r '.saturated // false')"
  echo "  github_ok:    $(echo "$plan" | jq -r '.github_ok // false')"
  echo
  echo "guests:"
  local name st base_id serial overlay
  local any=0
  for name in $(list_ci_domains); do
    any=1
    st=$(echo "$plan" | jq -r --arg n "$name" '.classify[$n] // "unknown"')
    base_id=$(read_guest_var "$name" BASE_ID)
    serial=$(read_guest_var "$name" SERIAL_LOG)
    overlay=$(read_guest_var "$name" OVERLAY)
    [[ -n "$serial" ]] || serial="$DATA_DIR/logs/${name}.serial.log"
    [[ -n "$overlay" ]] || overlay="$DATA_DIR/overlays/${name}.qcow2"
    printf '  %-40s  %-14s  base=%s\n' "$name" "$st" "${base_id:-unknown}"
    printf '      overlay=%s\n' "$overlay"
    printf '      serial=%s\n' "$serial"
  done
  if [[ "$any" -eq 0 ]]; then
    echo "  (none)"
  fi
  local cands
  cands=$(list_candidate_domains)
  if [[ -n "$cands" ]]; then
    echo
    echo "candidates (ignored by production pool):"
    for name in $cands; do
      echo "  $name  libvirt=$(virsh domstate "$name" 2>/dev/null | tr -d '[:space:]')"
      echo "      serial=$DATA_DIR/logs/${name}.serial.log"
    done
  fi
  write_metrics
}

# --- Candidate validation -------------------------------------------------

cleanup_candidate() {
  local name="$1"
  [[ -n "$name" ]] || return 0
  log "candidate cleanup: $name"
  destroy_guest "$name" || true
}

validate_candidate() {
  local qcow="${1:-}"
  shift || true
  local timeout=240
  local gh_repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        timeout="${2:-}"; shift 2 || { echo "usage: validate-candidate <qcow2> [--timeout N] [--github-repo OWNER/REPO]"; return 2; }
        ;;
      --github-repo)
        gh_repo="${2:-}"; shift 2 || { echo "usage: validate-candidate <qcow2> [--timeout N] [--github-repo OWNER/REPO]"; return 2; }
        ;;
      *)
        echo "unknown option: $1"
        echo "usage: ci-runnerctl validate-candidate <qcow2> [--timeout N] [--github-repo OWNER/REPO]"
        return 2
        ;;
    esac
  done
  [[ -n "$qcow" && -f "$qcow" ]] || {
    echo "usage: ci-runnerctl validate-candidate <qcow2> [--timeout N] [--github-repo OWNER/REPO]"
    return 2
  }
  qcow=$(readlink -f "$qcow")

  # Snapshot production guests so we can prove they were undisturbed.
  local before_prod before_spare
  before_prod=$(list_ci_domains | sort | tr '\n' ' ')
  before_spare=$(list_ci_domains | head -1 || true)

  local mode="dummy" rc=1 serial
  # Globals for EXIT trap: bash may unset function `local`s before the trap runs.
  _CI_CANDIDATE_NAME="${CANDIDATE_PREFIX}$(date +%Y%m%d%H%M%S)-$RANDOM"
  _CI_CANDIDATE_SERIAL="$DATA_DIR/logs/${_CI_CANDIDATE_NAME}.serial.log"
  _CI_CANDIDATE_BEFORE="$before_prod"
  serial="$_CI_CANDIDATE_SERIAL"

  cleanup_on_exit() {
    local exit_rc=$?
    cleanup_candidate "${_CI_CANDIDATE_NAME:-}"
    if [[ -n "${_CI_CANDIDATE_SERIAL:-}" && -f "$_CI_CANDIDATE_SERIAL" ]]; then
      echo
      echo "candidate serial log (retained): $_CI_CANDIDATE_SERIAL"
      echo "  inspect: sudo sed 's/\\x1b\\[[0-9;]*m//g' $_CI_CANDIDATE_SERIAL | tail -n 80"
    fi
    local after_prod
    after_prod=$(list_ci_domains | sort | tr '\n' ' ')
    echo "production domains before: ${_CI_CANDIDATE_BEFORE:-"(none)"}"
    echo "production domains after : ${after_prod:-"(none)"}"
    if [[ "${_CI_CANDIDATE_BEFORE:-}" != "$after_prod" ]]; then
      echo "WARNING: production domain set changed during candidate validation"
    else
      echo "production spare undisturbed: yes"
    fi
    unset _CI_CANDIDATE_NAME _CI_CANDIDATE_SERIAL _CI_CANDIDATE_BEFORE
    return "$exit_rc"
  }
  trap cleanup_on_exit EXIT

  log "validate-candidate: qcow=$qcow name=$_CI_CANDIDATE_NAME"

  if [[ -n "$gh_repo" ]]; then
    mode="runner"
    local owner repo token repo_url seed_iso overlay created
    owner="${gh_repo%%/*}"
    repo="${gh_repo#*/}"
    if [[ -z "$owner" || -z "$repo" || "$owner" == "$gh_repo" ]]; then
      echo "FAIL: --github-repo must be OWNER/REPO"
      return 2
    fi
    # Separate auth from the production GitHub App: prefer env override, else `gh`.
    # Under sudo, prefer the invoking user's gh auth (root usually has none).
    if [[ -n "${CI_RUNNER_REG_TOKEN:-}" ]]; then
      token="$CI_RUNNER_REG_TOKEN"
    elif [[ -n "${SUDO_USER:-}" ]] && command -v gh >/dev/null 2>&1; then
      token=$(sudo -u "$SUDO_USER" gh api -X POST "/repos/${owner}/${repo}/actions/runners/registration-token" -q .token) || {
        echo "FAIL: could not mint registration token via gh (as $SUDO_USER) for $owner/$repo"
        echo "      Set CI_RUNNER_REG_TOKEN or authenticate gh with admin on that repo."
        return 1
      }
    elif command -v gh >/dev/null 2>&1; then
      token=$(gh api -X POST "/repos/${owner}/${repo}/actions/runners/registration-token" -q .token) || {
        echo "FAIL: could not mint registration token via gh for $owner/$repo"
        echo "      Set CI_RUNNER_REG_TOKEN or authenticate gh with admin on that repo."
        return 1
      }
    else
      echo "FAIL: need CI_RUNNER_REG_TOKEN or authenticated gh for --github-repo mode"
      return 1
    fi
    local name="$_CI_CANDIDATE_NAME"
    created=$(date +%s)
    {
      echo "NAME=$name"
      echo "UPDATED_AT=$(date -Is)"
      echo "CREATED_AT_UNIX=$created"
      echo "MODE=runner"
      echo "VALIDATION_REPO=$owner/$repo"
      base_identity "$qcow"
      echo "SERIAL_LOG=$serial"
      echo "OVERLAY=$DATA_DIR/overlays/${name}.qcow2"
    } >"$(guest_state_path "$name")"
    overlay=$(create_overlay_from "$name" "$qcow")
    repo_url="https://github.com/${owner}/${repo}"
    seed_iso=$(make_seed_iso "$name" runner "$repo_url" "$token")
    unset token CI_RUNNER_REG_TOKEN
    if ! define_and_start "$name" "$overlay" "$seed_iso"; then
      echo "FAIL: candidate guest failed to start"
      return 1
    fi
    echo "candidate runner started: $name"
    echo "serial: $serial"
    echo "Dispatch a workflow on $owner/$repo targeting label $LABEL, then wait for poweroff."
    echo "This command will wait up to ${timeout}s for the guest to shut down."
    if wait_guest_poweroff "$name" "$timeout"; then
      echo "candidate powered off"
      if grep -q "runner exited rc=0" "$serial" 2>/dev/null; then
        echo "PASS: candidate GitHub validation (runner exited 0)"
        rc=0
      else
        echo "PASS: candidate powered off (inspect serial for job result)"
        rc=0
      fi
    else
      echo "FAIL: timeout waiting for candidate poweroff"
      echo "serial: $serial"
      rc=1
    fi
  else
    # Dummy isolation validation (default).
    local name="$_CI_CANDIDATE_NAME"
    local created overlay seed_iso
    created=$(date +%s)
    {
      echo "NAME=$name"
      echo "UPDATED_AT=$(date -Is)"
      echo "CREATED_AT_UNIX=$created"
      echo "MODE=dummy"
      base_identity "$qcow"
      echo "SERIAL_LOG=$serial"
      echo "OVERLAY=$DATA_DIR/overlays/${name}.qcow2"
    } >"$(guest_state_path "$name")"
    overlay=$(create_overlay_from "$name" "$qcow")
    seed_iso=$(make_seed_iso "$name" dummy)
    if ! define_and_start "$name" "$overlay" "$seed_iso"; then
      echo "FAIL: candidate guest failed to start"
      return 1
    fi
    if ! wait_guest_poweroff "$name" "$timeout"; then
      echo "FAIL: timeout waiting for candidate poweroff"
      echo "serial: $serial"
      return 1
    fi
    local missing=0
    for needle in \
      "public HTTPS ok" \
      "DNS ok" \
      "LAN HTTP blocked as expected" \
      "LAN ping blocked as expected" \
      "host SSH not reachable as expected" \
      "dummy workload complete"
    do
      if ! grep -qF "$needle" "$serial" 2>/dev/null; then
        echo "FAIL: serial missing expected marker: $needle"
        missing=1
      fi
    done
    if [[ "$missing" -ne 0 ]]; then
      echo "FAIL: dummy validation markers incomplete"
      rc=1
    else
      echo "PASS: candidate dummy validation"
      rc=0
    fi
  fi

  # Explicit cleanup before trap (destroy is idempotent).
  cleanup_candidate "${_CI_CANDIDATE_NAME:-}"
  _CI_CANDIDATE_NAME=""
  trap - EXIT
  if [[ -f "$serial" ]]; then
    echo "candidate serial log (retained): $serial"
    echo "  inspect: sudo sed 's/\\x1b\\[[0-9;]*m//g' $serial | tail -n 80"
  fi
  local after_prod
  after_prod=$(list_ci_domains | sort | tr '\n' ' ')
  echo "production domains before: ${before_prod:-"(none)"}"
  echo "production domains after : ${after_prod:-"(none)"}"
  if [[ "$before_prod" == "$after_prod" ]]; then
    echo "production spare undisturbed: yes"
  else
    echo "WARNING: production domain set changed during candidate validation"
  fi
  if [[ -n "$(list_candidate_domains)" ]]; then
    echo "WARNING: candidate domains still present: $(list_candidate_domains | tr '\n' ' ')"
  fi
  return "$rc"
}

wait_dummy_and_destroy() {
  local name="$1"
  local timeout="${2:-180}"
  if wait_guest_poweroff "$name" "$timeout"; then
    destroy_guest "$name"
    write_metrics
    return 0
  fi
  log "timeout waiting for $name; forcing destroy"
  destroy_guest "$name" || bump_counter "$STATE_DIR/teardown_failures"
  write_metrics
  return 1
}

cmd="${1:-}"
case "$cmd" in
  status)
    with_lock print_status
    ;;
  install-base)
    src="${2:-}"
    [[ -n "$src" && -f "$src" ]] || { echo "usage: ci-runnerctl install-base <path-to-qcow2>"; exit 2; }
    ensure_dirs
    dest="$DATA_DIR/base/ci-runner-base-$(date +%Y%m%d%H%M%S).qcow2"
    cp -f "$src" "$dest"
    chmod 0444 "$dest"
    sha256sum "$dest" | awk '{print $1}' >"${dest}.sha256"
    chmod 0444 "${dest}.sha256"
    ln -sfn "$dest" "$BASE_LINK"
    log "installed base $dest as current (BASE_ID=$(awk '{print substr($1,1,16)}' "${dest}.sha256"))"
    echo "installed: $dest"
    echo "BASE_ID=$(awk '{print substr($1,1,16)}' "${dest}.sha256")"
    echo "note: busy guests keep their pinned overlay backing file; recycle idle with:"
    echo "  sudo ci-runnerctl recycle-idle"
    ;;
  recycle-idle)
    with_lock recycle_idle
    ;;
  build-hint)
    echo "Build with: nix build /home/toka/nixosconfig#ci-runner-guest-image -L"
    echo "Then: sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2"
    echo "Then: sudo ci-runnerctl install-base result/ci-runner-base.qcow2"
    echo "Then: sudo ci-runnerctl recycle-idle"
    ;;
  reap)
    with_lock reap_orphans soft
    ;;
  reap-boot)
    with_lock reap_orphans boot
    ;;
  reconcile)
    with_lock reconcile
    ;;
  github-check)
    github_check
    ;;
  provision)
    with_lock provision_one runner
    ;;
  dummy)
    name=$(with_lock provision_one dummy) || exit $?
    name=$(echo "$name" | tail -n1 | tr -d '[:space:]')
    [[ -n "$name" ]] || { echo "dummy provision failed"; exit 1; }
    wait_dummy_and_destroy "$name" "${2:-240}"
    ;;
  validate-candidate)
    shift
    with_lock validate_candidate "$@"
    ;;
  destroy)
    name="${2:-}"
    [[ -n "$name" ]] || { echo "usage: ci-runnerctl destroy <domain>"; exit 2; }
    case "$name" in
      "${PREFIX}"*|"${CANDIDATE_PREFIX}"*) with_lock destroy_guest "$name" ;;
      *) echo "refusing to destroy non-managed domain: $name"; exit 2 ;;
    esac
    write_metrics
    ;;
  destroy-all)
    # Production only; never touches ci-candidate-*.
    with_lock reap_orphans boot
    ;;
  metrics)
    with_lock plan_pool >/dev/null
    write_metrics
    cat "$METRICS_FILE"
    ;;
  freshness)
    check_freshness
    ;;
  *)
    cat <<EOF
usage: ci-runnerctl <command>
  status
  install-base <qcow2>
  recycle-idle
  build-hint
  reap
  reap-boot
  reconcile
  github-check
  provision
  dummy [timeout_seconds]
  validate-candidate <qcow2> [--timeout N] [--github-repo OWNER/REPO]
  destroy <domain>
  destroy-all
  metrics
  freshness
EOF
    exit 2
    ;;
esac
