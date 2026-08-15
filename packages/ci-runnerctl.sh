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
HOST_MAX_GUESTS=@hostMaxGuests@
MEM=@guestMemoryMiB@
VCPUS=@guestVcpus@
LAN_PROBE=@lanProbeTarget@
# Space-separated default probe URLs from services.ciRunner.validationUrls
VALIDATION_URLS=@validationUrls@
GH_ENABLE=@githubEnable@
GH_OWNER=@githubOwner@
GH_REPO=@githubRepo@
GH_APP_ID=@githubAppId@
GH_INST_ID=@githubInstallationId@
GH_KEY=@githubPrivateKeyFile@
TEXTFILE_DIR=@textfileDir@
PROVISIONING_GRACE_SEC=@provisioningGraceSec@
POOLS_JSON=@poolsJson@
BASE_LINK="$DATA_DIR/base/current.qcow2"
STATE_DIR="$DATA_DIR/state"
GUEST_STATE_DIR="$STATE_DIR/guests"
LOCK_FILE="$STATE_DIR/provision.lock"
STATUS_FILE="$STATE_DIR/status.env"
POOL_FILE="$STATE_DIR/pool.json"
HOST_POOL_FILE="$STATE_DIR/host-pools.json"
METRICS_FILE="$TEXTFILE_DIR/ci_runner.prom"
FRESHNESS_FILE="$TEXTFILE_DIR/ci_runner_freshness.prom"
TOKEN_CACHE="$STATE_DIR/github_installation_token"
TOKEN_CACHE_EXP="$STATE_DIR/github_installation_token.exp"
POOL_BIN=@poolBin@
GH_APP_TOKEN_BIN=@ghAppTokenBin@

export PATH=@path@:$PATH

log() { echo "ci-runnerctl: $*" >&2; logger -t ci-runnerctl "$*" 2>/dev/null || true; }

# --- Multi-pool helpers ---------------------------------------------------

pool_ids() {
  jq -r '.pools[].id' "$POOLS_JSON"
}

pool_json() {
  local id="$1"
  jq -c --arg id "$id" '.pools[] | select(.id==$id)' "$POOLS_JSON"
}

pool_field() {
  local id="$1" field="$2"
  pool_json "$id" | jq -r --arg f "$field" '.[$f]'
}

all_prod_prefixes() {
  jq -r '.pools[].prefix' "$POOLS_JSON"
}

all_cand_prefixes() {
  jq -r '.pools[].candidate_prefix' "$POOLS_JSON"
}

is_managed_domain() {
  local name="$1" pfx
  for pfx in $(all_prod_prefixes) $(all_cand_prefixes); do
    [[ -n "$pfx" ]] || continue
    case "$name" in
      "${pfx}"*) return 0 ;;
    esac
  done
  return 1
}

pool_id_for_domain() {
  local name="$1" id pfx
  for id in $(pool_ids); do
    pfx=$(pool_field "$id" prefix)
    case "$name" in
      "${pfx}"*) echo "$id"; return 0 ;;
    esac
  done
  return 1
}

list_pool_domains() {
  local id="$1"
  list_prefixed_domains "$(pool_field "$id" prefix)"
}

list_all_prod_domains() {
  local id
  for id in $(pool_ids); do
    list_pool_domains "$id"
  done
}

list_all_candidate_domains() {
  local pfx
  for pfx in $(all_cand_prefixes); do
    [[ -n "$pfx" ]] || continue
    list_prefixed_domains "$pfx"
  done
}

domain_names_json() {
  # Emit JSON array of {name} objects from newline-separated domain names on stdin.
  jq -Rnc '[inputs | select(length>0) | {name: .}]'
}

admit_production_or_refuse() {
  # Final host/pool capacity guard before creating a production guest. Must run under flock.
  local pool_id="$1"
  local pfx maxg domains snap decision reason
  pfx=$(pool_field "$pool_id" prefix)
  maxg=$(pool_field "$pool_id" max_guests)
  domains=$( {
    list_all_prod_domains
    list_all_candidate_domains
  } | domain_names_json )
  snap=$(jq -nc \
    --argjson host_max "$HOST_MAX_GUESTS" \
    --argjson pool_max "$maxg" \
    --arg pfx "$pfx" \
    --argjson domains "$domains" \
    --slurpfile poolsfile "$POOLS_JSON" \
    '{
      host_max_guests: $host_max,
      pool_max_guests: $pool_max,
      pool_prefix: $pfx,
      production_prefixes: [$poolsfile[0].pools[].prefix],
      candidate_prefixes: [$poolsfile[0].pools[].candidate_prefix],
      domains: $domains
    }')
  decision=$(echo "$snap" | "$POOL_BIN" admit-production)
  if [[ "$(echo "$decision" | jq -r '.allowed')" != "true" ]]; then
    reason=$(echo "$decision" | jq -r '.reason')
    log "refusing production provision pool=$pool_id reason=$reason $(echo "$decision" | jq -c '{pool_total,production_total,physical_total,host_max,pool_max}')"
    return 1
  fi
  return 0
}

admit_candidate_or_refuse() {
  # Physical safety guard before starting a candidate. Must run under flock.
  local allow_overcommit="${1:-0}"
  local domains snap decision reason
  domains=$( {
    list_all_prod_domains
    list_all_candidate_domains
  } | domain_names_json )
  snap=$(jq -nc \
    --argjson physical_max "$HOST_MAX_GUESTS" \
    --argjson overcommit "$([[ "$allow_overcommit" == "1" ]] && echo true || echo false)" \
    --argjson domains "$domains" \
    --slurpfile poolsfile "$POOLS_JSON" \
    '{
      physical_max_guests: $physical_max,
      allow_overcommit: $overcommit,
      production_prefixes: [$poolsfile[0].pools[].prefix],
      candidate_prefixes: [$poolsfile[0].pools[].candidate_prefix],
      domains: $domains
    }')
  decision=$(echo "$snap" | "$POOL_BIN" admit-candidate)
  if [[ "$(echo "$decision" | jq -r '.allowed')" != "true" ]]; then
    reason=$(echo "$decision" | jq -r '.reason')
    log "refusing candidate start reason=$reason $(echo "$decision" | jq -c '{production_total,candidate_total,physical_total,physical_max}')"
    echo "FAIL: candidate would exceed physical guest ceiling (hostMaxGuests=$HOST_MAX_GUESTS includes production + candidates)."
    echo "      Occupancy: $(echo "$decision" | jq -c '{production_total,candidate_total,physical_total,physical_max}')"
    echo "      Retry when a slot is free, or pass --allow-capacity-overcommit (explicit, warned bypass)."
    return 1
  fi
  if [[ "$(echo "$decision" | jq -r '.reason')" == "overcommit_override" ]]; then
    log "WARNING: candidate capacity overcommit override in effect — bypassing physical safety ceiling"
    echo "WARNING: --allow-capacity-overcommit bypasses the physical guest safety ceiling (hostMaxGuests=$HOST_MAX_GUESTS)."
    echo "         This can oversubscribe RAM/vCPU on the live host. Do not use for normal automation."
  fi
  return 0
}

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
  if ! is_managed_domain "$name"; then
    log "refusing to destroy non-managed domain: $name"
    return 2
  fi
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
  # mode=boot → destroy every production guest across all pools (post-reboot / fail-closed)
  # mode=soft → destroy only non-running production guests + orphan disks
  # Candidate (*-candidate-*) resources are NEVER touched by production reaping.
  local mode="${1:-soft}"
  log "reaping stale runner resources mode=$mode pools=$(pool_ids | tr '\n' ',')"
  local cleaned=0 d state id pfx
  for id in $(pool_ids); do
    pfx=$(pool_field "$id" prefix)
    for d in $(list_prefixed_domains "$pfx"); do
      state=$(virsh domstate "$d" 2>/dev/null | tr -d '[:space:]' || echo missing)
      if [[ "$mode" == "boot" ]]; then
        log "reaper(boot): removing domain $d pool=$id (state=$state)"
        destroy_guest "$d"
        cleaned=$((cleaned + 1))
      else
        case "$state" in
          running)
            log "reaper(soft): leaving running guest $d"
            ;;
          *)
            log "reaper(soft): removing non-running domain $d pool=$id (state=$state)"
            destroy_guest "$d"
            cleaned=$((cleaned + 1))
            ;;
        esac
      fi
    done
  done
  local f base
  if [[ -d "$DATA_DIR/overlays" ]]; then
    for id in $(pool_ids); do
      pfx=$(pool_field "$id" prefix)
      for f in "$DATA_DIR/overlays"/${pfx}*.qcow2; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f" .qcow2)
        if ! virsh dominfo "$base" >/dev/null 2>&1; then
          log "reaper: removing orphan overlay $f"
          rm -f "$f"
          cleaned=$((cleaned + 1))
        fi
      done
    done
  fi
  if [[ -d "$DATA_DIR/seeds" ]]; then
    for id in $(pool_ids); do
      pfx=$(pool_field "$id" prefix)
      for f in "$DATA_DIR/seeds"/${pfx}*.iso; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f" .iso)
        if ! virsh dominfo "$base" >/dev/null 2>&1; then
          log "reaper: removing orphan seed $f"
          rm -f "$f"
          cleaned=$((cleaned + 1))
        fi
      done
      for f in "$DATA_DIR/seeds"/${pfx}*.dir; do
        [[ -d "$f" ]] || continue
        base=$(basename "$f" .dir)
        if ! virsh dominfo "$base" >/dev/null 2>&1; then
          log "reaper: removing orphan seed dir $f"
          rm -rf "$f"
          cleaned=$((cleaned + 1))
        fi
      done
    done
  fi
  if [[ -d "$GUEST_STATE_DIR" ]]; then
    for id in $(pool_ids); do
      pfx=$(pool_field "$id" prefix)
      for f in "$GUEST_STATE_DIR"/${pfx}*.env; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f" .env)
        if ! virsh dominfo "$base" >/dev/null 2>&1; then
          log "reaper: removing orphan guest state $f"
          rm -f "$f"
          cleaned=$((cleaned + 1))
        fi
      done
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
  # Optional 5th arg (dummy) or ignored: space-separated HTTPS probe URLs.
  local probe_urls="${PROBE_URLS_OVERRIDE:-${VALIDATION_URLS:-}}"
  local runner_labels="${RUNNER_LABELS_OVERRIDE:-$LABEL,self-hosted,Linux,X64}"
  mkdir -p "$DATA_DIR/seeds"
  rm -rf "$seed_dir"
  mkdir -p "$seed_dir"
  {
    echo "MODE=$mode"
    echo "LAN_PROBE_TARGET=$LAN_PROBE"
    if [[ -n "$probe_urls" ]]; then
      echo "PROBE_URLS=$probe_urls"
    fi
    if [[ -n "${CURSOR_CLI_VERSION:-}" ]]; then
      echo "CURSOR_CLI_VERSION=$CURSOR_CLI_VERSION"
    fi
    if [[ "$mode" == "runner" ]]; then
      echo "REPO_URL=$3"
      echo "REGISTRATION_TOKEN=$4"
      echo "RUNNER_NAME=$name"
      echo "RUNNER_LABELS=$runner_labels"
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
  local mem_mib="${4:-$MEM}"
  local vcpus="${5:-$VCPUS}"
  local serial_log="$DATA_DIR/logs/${name}.serial.log"
  mkdir -p "$DATA_DIR/logs"
  : >"$serial_log"
  virsh destroy "$name" 2>/dev/null || true
  virsh undefine "$name" 2>/dev/null || true
  virt-install \
    --connect qemu:///system \
    --name "$name" \
    --memory "$mem_mib" \
    --vcpus "$vcpus" \
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
  # Multi-pool host plan. Writes HOST_POOL_FILE and legacy POOL_FILE (ci subset).
  local now domains snap plan id owner repo runners github_ok
  local runners_by_pool='{}' github_ok_by_pool='{}'
  now=$(date +%s)
  domains=$(collect_domain_snapshot_json)

  for id in $(pool_ids); do
    github_ok=false
    runners='[]'
    owner=$(pool_field "$id" github_owner)
    repo=$(pool_field "$id" github_repo)
    if [[ "$(pool_field "$id" github_enable)" == "true" ]]; then
      if runners=$(list_github_runners_json "$owner" "$repo" 2>/dev/null); then
        github_ok=true
      else
        log "GitHub API unavailable for pool=$id ($owner/$repo) — fail-closed"
        runners='[]'
        github_ok=false
      fi
    else
      log "GitHub disabled for pool=$id; will not provision"
      github_ok=false
    fi
    runners=$(echo "$runners" | jq -c '[.[] | {name, status, busy: (.busy // false)}]')
    runners_by_pool=$(jq -nc --argjson cur "$runners_by_pool" --arg id "$id" --argjson r "$runners" \
      '$cur + {($id): $r}')
    github_ok_by_pool=$(jq -nc --argjson cur "$github_ok_by_pool" --arg id "$id" --argjson ok "$github_ok" \
      '$cur + {($id): $ok}')
  done

  snap=$(jq -nc \
    --argjson domains "$domains" \
    --argjson runners_by_pool "$runners_by_pool" \
    --argjson github_ok_by_pool "$github_ok_by_pool" \
    --argjson now "$now" \
    --argjson host_max "$HOST_MAX_GUESTS" \
    --argjson grace "$PROVISIONING_GRACE_SEC" \
    --slurpfile poolsfile "$POOLS_JSON" \
    '{
      mode: "multi",
      host: {host_max_guests: $host_max},
      pools: ($poolsfile[0].pools | map(. + {provisioning_grace_sec: $grace})),
      now: $now,
      domains: $domains,
      runners_by_pool: $runners_by_pool,
      github_ok_by_pool: $github_ok_by_pool
    }')
  plan=$(echo "$snap" | "$POOL_BIN" plan)
  echo "$plan" >"$HOST_POOL_FILE.tmp"
  mv -f "$HOST_POOL_FILE.tmp" "$HOST_POOL_FILE"
  # Legacy single-pool file: CI subset when present, else first pool.
  if echo "$plan" | jq -e '.pools.ci' >/dev/null 2>&1; then
    echo "$plan" | jq '.pools.ci' >"$POOL_FILE.tmp"
  else
    echo "$plan" | jq '.pools | to_entries[0].value' >"$POOL_FILE.tmp"
  fi
  mv -f "$POOL_FILE.tmp" "$POOL_FILE"
  echo "$plan"
}

write_metrics() {
  mkdir -p "$TEXTFILE_DIR"
  local plan='{}'
  [[ -f "$HOST_POOL_FILE" ]] && plan=$(cat "$HOST_POOL_FILE")
  local overlay_bytes=0
  if [[ -d "$DATA_DIR/overlays" ]]; then
    overlay_bytes=$(du -sb "$DATA_DIR/overlays" 2>/dev/null | awk '{print $1}')
  fi
  local provision_ts=0 provision_fail=0 teardown_fail=0 orphan_clean=0
  [[ -f "$STATE_DIR/provision_success_ts" ]] && provision_ts=$(cat "$STATE_DIR/provision_success_ts")
  [[ -f "$STATE_DIR/provision_failures" ]] && provision_fail=$(cat "$STATE_DIR/provision_failures")
  [[ -f "$STATE_DIR/teardown_failures" ]] && teardown_fail=$(cat "$STATE_DIR/teardown_failures")
  [[ -f "$STATE_DIR/orphan_cleanup" ]] && orphan_clean=$(cat "$STATE_DIR/orphan_cleanup")

  local host_total host_max host_sat
  host_total=$(echo "$plan" | jq -r '.host_total // 0')
  host_max=$(echo "$plan" | jq -r ".host_max // $HOST_MAX_GUESTS")
  host_sat=$(echo "$plan" | jq -r 'if .host_saturated then 1 else 0 end')

  local tmp="$METRICS_FILE.$$.tmp"
  {
    echo '# HELP runner_host_total Managed production guests across all pools (after planned destroys).'
    echo '# TYPE runner_host_total gauge'
    echo "runner_host_total $host_total"
    echo '# HELP runner_host_max_guests Host-wide hard ceiling on managed production guests.'
    echo '# TYPE runner_host_max_guests gauge'
    echo "runner_host_max_guests $host_max"
    echo '# HELP runner_host_saturated 1 when host_total_after_provision >= host_max.'
    echo '# TYPE runner_host_saturated gauge'
    echo "runner_host_saturated $host_sat"

    local id idle busy provisioning uncertain total saturated github_ok desired maxg
    for id in $(pool_ids); do
      idle=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.idle // 0')
      busy=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.busy // 0')
      provisioning=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.provisioning // 0')
      uncertain=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.uncertain // 0')
      total=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.total // 0')
      saturated=$(echo "$plan" | jq -r --arg id "$id" 'if .pools[$id].saturated then 1 else 0 end')
      github_ok=$(echo "$plan" | jq -r --arg id "$id" 'if .pools[$id].github_ok then 1 else 0 end')
      desired=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].desired_idle // 0')
      maxg=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].max_guests // 0')
      echo "# HELP runner_pool_idle Healthy online idle runners (pool label)."
      echo "# TYPE runner_pool_idle gauge"
      echo "runner_pool_idle{pool=\"$id\"} $idle"
      echo "# HELP runner_pool_busy Healthy online busy runners (pool label)."
      echo "# TYPE runner_pool_busy gauge"
      echo "runner_pool_busy{pool=\"$id\"} $busy"
      echo "# HELP runner_pool_provisioning Guests still registering (pool label)."
      echo "# TYPE runner_pool_provisioning gauge"
      echo "runner_pool_provisioning{pool=\"$id\"} $provisioning"
      echo "# HELP runner_pool_uncertain Unclassifiable running guests (pool label)."
      echo "# TYPE runner_pool_uncertain gauge"
      echo "runner_pool_uncertain{pool=\"$id\"} $uncertain"
      echo "# HELP runner_pool_total Managed guests counting toward pool max (pool label)."
      echo "# TYPE runner_pool_total gauge"
      echo "runner_pool_total{pool=\"$id\"} $total"
      echo "# HELP runner_pool_max_guests Per-pool hard cap."
      echo "# TYPE runner_pool_max_guests gauge"
      echo "runner_pool_max_guests{pool=\"$id\"} $maxg"
      echo "# HELP runner_pool_desired_idle Per-pool desired idle capacity."
      echo "# TYPE runner_pool_desired_idle gauge"
      echo "runner_pool_desired_idle{pool=\"$id\"} $desired"
      echo "# HELP runner_pool_saturated 1 when pool idle==0 and total>=max."
      echo "# TYPE runner_pool_saturated gauge"
      echo "runner_pool_saturated{pool=\"$id\"} $saturated"
      echo "# HELP runner_pool_github_ok 1 if last plan reached GitHub for this pool."
      echo "# TYPE runner_pool_github_ok gauge"
      echo "runner_pool_github_ok{pool=\"$id\"} $github_ok"
    done

    # Backward-compatible unlabelled CI metrics (ci pool, or zeros).
    local ci_idle ci_busy ci_prov ci_unc ci_total ci_sat ci_gh ci_des ci_max
    ci_idle=$(echo "$plan" | jq -r '.pools.ci.counts.idle // 0')
    ci_busy=$(echo "$plan" | jq -r '.pools.ci.counts.busy // 0')
    ci_prov=$(echo "$plan" | jq -r '.pools.ci.counts.provisioning // 0')
    ci_unc=$(echo "$plan" | jq -r '.pools.ci.counts.uncertain // 0')
    ci_total=$(echo "$plan" | jq -r '.pools.ci.counts.total // 0')
    ci_sat=$(echo "$plan" | jq -r 'if .pools.ci.saturated then 1 else 0 end')
    ci_gh=$(echo "$plan" | jq -r 'if .pools.ci.github_ok then 1 else 0 end')
    ci_des=$(echo "$plan" | jq -r ".pools.ci.desired_idle // $DESIRED")
    ci_max=$(echo "$plan" | jq -r ".pools.ci.max_guests // $MAX_GUESTS")
    echo '# HELP ci_runner_idle Healthy online managed runners with busy=false (CI pool; legacy).'
    echo '# TYPE ci_runner_idle gauge'
    echo "ci_runner_idle $ci_idle"
    echo '# HELP ci_runner_busy Healthy online managed runners with busy=true (CI pool; legacy).'
    echo '# TYPE ci_runner_busy gauge'
    echo "ci_runner_busy $ci_busy"
    echo '# HELP ci_runner_provisioning Local running CI guests not yet online on GitHub.'
    echo '# TYPE ci_runner_provisioning gauge'
    echo "ci_runner_provisioning $ci_prov"
    echo '# HELP ci_runner_uncertain Running CI guests that cannot be safely classified.'
    echo '# TYPE ci_runner_uncertain gauge'
    echo "ci_runner_uncertain $ci_unc"
    echo '# HELP ci_runner_total Managed CI guests counting toward CI maxGuests.'
    echo '# TYPE ci_runner_total gauge'
    echo "ci_runner_total $ci_total"
    echo '# HELP ci_runner_max_guests CI pool hard cap.'
    echo '# TYPE ci_runner_max_guests gauge'
    echo "ci_runner_max_guests $ci_max"
    echo '# HELP ci_runner_desired_idle CI pool desired idle capacity.'
    echo '# TYPE ci_runner_desired_idle gauge'
    echo "ci_runner_desired_idle $ci_des"
    echo '# HELP ci_runner_saturated 1 when CI idle==0 and total>=maxGuests.'
    echo '# TYPE ci_runner_saturated gauge'
    echo "ci_runner_saturated $ci_sat"
    echo '# HELP ci_runner_github_ok 1 if the last CI pool plan successfully queried GitHub.'
    echo '# TYPE ci_runner_github_ok gauge'
    echo "ci_runner_github_ok $ci_gh"
    echo '# HELP ci_runner_clean_capacity Alias of ci_runner_idle (legacy).'
    echo '# TYPE ci_runner_clean_capacity gauge'
    echo "ci_runner_clean_capacity $ci_idle"
    echo '# HELP ci_runner_guest_active 1 if any managed CI guest exists (legacy).'
    echo '# TYPE ci_runner_guest_active gauge'
    echo "ci_runner_guest_active $([[ "$ci_total" -gt 0 ]] && echo 1 || echo 0)"
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
    echo '# HELP ci_runner_overlay_bytes Bytes used by runner overlay disks'
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
  local pool_id="${2:-ci}"
  local base_path="${3:-}"
  local name_prefix_override="${4:-}"

  local owner repo label pfx mem_mib vcpus maxg count
  owner=$(pool_field "$pool_id" github_owner)
  repo=$(pool_field "$pool_id" github_repo)
  label=$(pool_field "$pool_id" runner_label)
  pfx=$(pool_field "$pool_id" prefix)
  mem_mib=$(pool_field "$pool_id" guest_memory_mib)
  vcpus=$(pool_field "$pool_id" guest_vcpus)
  maxg=$(pool_field "$pool_id" max_guests)

  if [[ -z "$base_path" ]]; then
    require_base
    base_path=$(resolve_base)
  fi
  [[ -f "$base_path" ]] || { log "base image not found: $base_path"; return 1; }

  local name_prefix="${name_prefix_override:-$pfx}"
  # Production prefix: enforce per-pool max + hostMaxGuests + physical ceiling
  # (including candidates) at the creation site — not only in the planner.
  if [[ "$name_prefix" == "$pfx" ]]; then
    if ! admit_production_or_refuse "$pool_id"; then
      return 1
    fi
  fi

  local name overlay seed_iso token repo_url created
  name="${name_prefix}$(date +%Y%m%d%H%M%S)-$RANDOM"
  created=$(date +%s)
  log "provisioning $name mode=$mode pool=$pool_id base=$base_path"

  {
    echo "NAME=$name"
    echo "UPDATED_AT=$(date -Is)"
    echo "CREATED_AT_UNIX=$created"
    echo "MODE=$mode"
    echo "POOL_ID=$pool_id"
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
    RUNNER_LABELS_OVERRIDE="${label},self-hosted,Linux,X64"
    export RUNNER_LABELS_OVERRIDE
    seed_iso=$(make_seed_iso "$name" runner "$repo_url" "$token")
    unset token RUNNER_LABELS_OVERRIDE
  else
    seed_iso=$(make_seed_iso "$name" dummy)
  fi
  if ! define_and_start "$name" "$overlay" "$seed_iso" "$mem_mib" "$vcpus"; then
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
    echo "POOL_ID=$pool_id"
    base_identity "$base_path"
    echo "SERIAL_LOG=$DATA_DIR/logs/${name}.serial.log"
    echo "OVERLAY=$overlay"
    echo "POOL_STATE=provisioning"
  } >"$(guest_state_path "$name")"
  log "provisioned $name"
  echo "$name"
}

reconcile() {
  log "reconcile start host_max=$HOST_MAX_GUESTS pools=$(pool_ids | tr '\n' ',')"
  ensure_dirs
  local plan destroy_list name to_prov id i
  plan=$(plan_pool)
  log "host: total=$(echo "$plan" | jq -r '.host_total') max=$(echo "$plan" | jq -r '.host_max') saturated=$(echo "$plan" | jq -r '.host_saturated')"
  for id in $(pool_ids); do
    log "pool=$id idle=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.idle') busy=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.busy') provisioning=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.provisioning') total=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.total') provision=$(echo "$plan" | jq -r --arg id "$id" '.provision[$id] // .pools[$id].provision') github_ok=$(echo "$plan" | jq -r --arg id "$id" '.pools[$id].github_ok')"
  done

  destroy_list=$(echo "$plan" | jq -r '.destroy[]?')
  for name in $destroy_list; do
    [[ -n "$name" ]] || continue
    log "reconcile: destroying $name"
    destroy_guest "$name" || bump_counter "$STATE_DIR/teardown_failures"
  done

  for id in $(pool_ids); do
    if [[ "$(pool_field "$id" github_enable)" == "true" ]]; then
      PREFIX=$(pool_field "$id" prefix)
      GH_OWNER=$(pool_field "$id" github_owner)
      GH_REPO=$(pool_field "$id" github_repo)
      GH_ENABLE=1
      delete_stale_github_runners || true
    fi
  done
  PREFIX=@domainPrefix@
  GH_OWNER=@githubOwner@
  GH_REPO=@githubRepo@
  GH_ENABLE=@githubEnable@

  plan=$(plan_pool)
  # Higher priority first (planner already ordered allocations; honor priority here too).
  local ordered
  ordered=$(jq -r '.pools | sort_by(-.priority) | .[].id' "$POOLS_JSON")
  for id in $ordered; do
    to_prov=$(echo "$plan" | jq -r --arg id "$id" '.provision[$id] // 0')
    if [[ "$(pool_field "$id" github_enable)" != "true" ]]; then
      to_prov=0
    fi
    i=0
    while [[ "$i" -lt "$to_prov" ]]; do
      log "reconcile: provisioning pool=$id ($((i + 1))/$to_prov)"
      provision_one runner "$id" || true
      i=$((i + 1))
    done
  done

  plan=$(plan_pool)
  write_status pool \
    "HOST_TOTAL=$(echo "$plan" | jq -r '.host_total')" \
    "HOST_MAX=$(echo "$plan" | jq -r '.host_max')" \
    "HOST_SATURATED=$(echo "$plan" | jq -r '.host_saturated')"
  write_metrics
  log "reconcile done"
}

recycle_idle() {
  # Destroy only healthy idle production guests (all pools) so they are replaced
  # from the current base. Busy guests finish on their pinned overlay/base.
  local pool_filter="${1:-}"
  log "recycle-idle start filter=${pool_filter:-all}"
  local plan name id
  plan=$(plan_pool)
  for id in $(pool_ids); do
    if [[ -n "$pool_filter" && "$id" != "$pool_filter" ]]; then
      continue
    fi
    echo "$plan" | jq -r --arg id "$id" '
      .pools[$id].classify // {} | to_entries[] | select(.value=="idle") | .key' \
      | while read -r name; do
          [[ -n "$name" ]] || continue
          log "recycle-idle: destroying idle guest $name pool=$id"
          destroy_guest "$name" || bump_counter "$STATE_DIR/teardown_failures"
        done
  done
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
  local plan base_resolved id
  base_resolved=$(readlink -f "$BASE_LINK" 2>/dev/null || echo missing)
  echo "DATA_DIR=$DATA_DIR"
  echo "BASE_LINK=$BASE_LINK -> $base_resolved"
  if [[ -f "$base_resolved" ]]; then
    echo "BASE_ID=$(sha256sum "$base_resolved" | awk '{print substr($1,1,16)}')"
  fi
  echo "NETWORK=$NETWORK BRIDGE=$BRIDGE"
  echo "HOST_MAX_GUESTS=$HOST_MAX_GUESTS"
  plan=$(plan_pool 2>/dev/null || echo '{}')
  echo
  echo "host capacity:"
  echo "  maximum:      $(echo "$plan" | jq -r ".host_max // $HOST_MAX_GUESTS")"
  echo "  total:        $(echo "$plan" | jq -r '.host_total // 0')"
  echo "  after_prov:   $(echo "$plan" | jq -r '.host_total_after_provision // 0')"
  echo "  saturated:    $(echo "$plan" | jq -r '.host_saturated // false')"
  for id in $(pool_ids); do
    echo
    echo "pool $id:"
    echo "  label:        $(pool_field "$id" runner_label)"
    echo "  prefix:       $(pool_field "$id" prefix)"
    echo "  repo:         $(pool_field "$id" github_owner)/$(pool_field "$id" github_repo)"
    echo "  github:       $(pool_field "$id" github_enable)"
    echo "  desired idle: $(pool_field "$id" desired_idle)"
    echo "  max guests:   $(pool_field "$id" max_guests)"
    echo "  reserved:     $(pool_field "$id" reserved_host_slots)"
    echo "  priority:     $(pool_field "$id" priority)"
    echo "  total:        $(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.total // 0')"
    echo "  idle:         $(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.idle // 0')"
    echo "  busy:         $(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.busy // 0')"
    echo "  provisioning: $(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.provisioning // 0')"
    echo "  uncertain:    $(echo "$plan" | jq -r --arg id "$id" '.pools[$id].counts.uncertain // 0')"
    echo "  saturated:    $(echo "$plan" | jq -r --arg id "$id" '.pools[$id].saturated // false')"
    echo "  github_ok:    $(echo "$plan" | jq -r --arg id "$id" '.pools[$id].github_ok // false')"
    echo "  provision:    $(echo "$plan" | jq -r --arg id "$id" '.provision[$id] // 0')"
    echo "  guests:"
    local name st base_id serial overlay any=0
    for name in $(list_pool_domains "$id"); do
      any=1
      st=$(echo "$plan" | jq -r --arg id "$id" --arg n "$name" '.pools[$id].classify[$n] // "unknown"')
      base_id=$(read_guest_var "$name" BASE_ID)
      serial=$(read_guest_var "$name" SERIAL_LOG)
      overlay=$(read_guest_var "$name" OVERLAY)
      [[ -n "$serial" ]] || serial="$DATA_DIR/logs/${name}.serial.log"
      [[ -n "$overlay" ]] || overlay="$DATA_DIR/overlays/${name}.qcow2"
      printf '    %-40s  %-14s  base=%s\n' "$name" "$st" "${base_id:-unknown}"
      printf '        overlay=%s\n' "$overlay"
      printf '        serial=%s\n' "$serial"
    done
    if [[ "$any" -eq 0 ]]; then
      echo "    (none)"
    fi
  done
  local cands="" cand_pfx
  for cand_pfx in $(all_cand_prefixes); do
    cands+=$(list_prefixed_domains "$cand_pfx")
    cands+=$'\n'
  done
  cands=$(echo "$cands" | sed '/^$/d' || true)
  if [[ -n "$cands" ]]; then
    echo
    echo "candidates (ignored by production pools):"
    local name
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
  local pool_id="ci"
  local allow_overcommit=0
  local probe_urls=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        timeout="${2:-}"; shift 2 || { echo "usage: validate-candidate <qcow2> [--pool ID] [--timeout N] [--github-repo OWNER/REPO] [--probe-url URL] [--allow-capacity-overcommit]"; return 2; }
        ;;
      --pool)
        pool_id="${2:-}"; shift 2 || { echo "usage: validate-candidate <qcow2> [--pool ID] ..."; return 2; }
        ;;
      --github-repo)
        gh_repo="${2:-}"; shift 2 || { echo "usage: validate-candidate <qcow2> [--pool ID] [--timeout N] [--github-repo OWNER/REPO] [--probe-url URL] [--allow-capacity-overcommit]"; return 2; }
        ;;
      --probe-url)
        [[ -n "${2:-}" ]] || { echo "usage: validate-candidate <qcow2> [--probe-url URL]"; return 2; }
        probe_urls+=("$2")
        shift 2
        ;;
      --allow-capacity-overcommit)
        allow_overcommit=1
        shift
        ;;
      *)
        echo "unknown option: $1"
        echo "usage: ci-runnerctl validate-candidate <qcow2> [--pool ID] [--timeout N] [--github-repo OWNER/REPO] [--probe-url URL]... [--allow-capacity-overcommit]"
        return 2
        ;;
    esac
  done
  [[ -n "$qcow" && -f "$qcow" ]] || {
    echo "usage: ci-runnerctl validate-candidate <qcow2> [--pool ID] [--timeout N] [--github-repo OWNER/REPO] [--probe-url URL]"
    return 2
  }
  pool_json "$pool_id" >/dev/null || { echo "FAIL: unknown pool id: $pool_id"; return 2; }
  local cand_prefix label mem_mib vcpus
  cand_prefix=$(pool_field "$pool_id" candidate_prefix)
  label=$(pool_field "$pool_id" runner_label)
  mem_mib=$(pool_field "$pool_id" guest_memory_mib)
  vcpus=$(pool_field "$pool_id" guest_vcpus)
  qcow=$(readlink -f "$qcow")
  if [[ ${#probe_urls[@]} -gt 0 ]]; then
    PROBE_URLS_OVERRIDE="${probe_urls[*]}"
  else
    PROBE_URLS_OVERRIDE="${VALIDATION_URLS:-}"
  fi
  export PROBE_URLS_OVERRIDE

  local before_prod
  before_prod=$(list_all_prod_domains | sort | tr '\n' ' ')

  local mode="dummy" rc=1 serial
  _CI_CANDIDATE_NAME="${cand_prefix}$(date +%Y%m%d%H%M%S)-$RANDOM"
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
    after_prod=$(list_all_prod_domains | sort | tr '\n' ' ')
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

  log "validate-candidate: qcow=$qcow pool=$pool_id name=$_CI_CANDIDATE_NAME"

  # Physical safety: candidates are outside production reconciliation but still
  # consume RAM/vCPU. Refuse by default when production+candidates already at
  # hostMaxGuests. Runs under the same flock as provision/reconcile.
  if ! admit_candidate_or_refuse "$allow_overcommit"; then
    _CI_CANDIDATE_NAME=""
    trap - EXIT
    return 1
  fi

  if [[ -n "$gh_repo" ]]; then
    mode="runner"
    local owner repo token repo_url seed_iso overlay created
    owner="${gh_repo%%/*}"
    repo="${gh_repo#*/}"
    if [[ -z "$owner" || -z "$repo" || "$owner" == "$gh_repo" ]]; then
      echo "FAIL: --github-repo must be OWNER/REPO"
      return 2
    fi
    if [[ -n "${CI_RUNNER_REG_TOKEN:-}" ]]; then
      token="$CI_RUNNER_REG_TOKEN"
    elif [[ -n "${SUDO_USER:-}" ]] && command -v gh >/dev/null 2>&1; then
      token=$(sudo -u "$SUDO_USER" gh api -X POST "/repos/${owner}/${repo}/actions/runners/registration-token" -q .token) || {
        echo "FAIL: could not mint registration token via gh (as $SUDO_USER) for $owner/$repo"
        return 1
      }
    elif command -v gh >/dev/null 2>&1; then
      token=$(gh api -X POST "/repos/${owner}/${repo}/actions/runners/registration-token" -q .token) || {
        echo "FAIL: could not mint registration token via gh for $owner/$repo"
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
      echo "POOL_ID=$pool_id"
      echo "VALIDATION_REPO=$owner/$repo"
      base_identity "$qcow"
      echo "SERIAL_LOG=$serial"
      echo "OVERLAY=$DATA_DIR/overlays/${name}.qcow2"
    } >"$(guest_state_path "$name")"
    overlay=$(create_overlay_from "$name" "$qcow")
    repo_url="https://github.com/${owner}/${repo}"
    RUNNER_LABELS_OVERRIDE="${label},self-hosted,Linux,X64"
    export RUNNER_LABELS_OVERRIDE
    seed_iso=$(make_seed_iso "$name" runner "$repo_url" "$token")
    unset token CI_RUNNER_REG_TOKEN RUNNER_LABELS_OVERRIDE
    if ! define_and_start "$name" "$overlay" "$seed_iso" "$mem_mib" "$vcpus"; then
      echo "FAIL: candidate guest failed to start"
      return 1
    fi
    echo "candidate runner started: $name"
    echo "serial: $serial"
    echo "Dispatch a workflow on $owner/$repo targeting label $label, then wait for poweroff."
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
    local name="$_CI_CANDIDATE_NAME"
    local created overlay seed_iso
    created=$(date +%s)
    {
      echo "NAME=$name"
      echo "UPDATED_AT=$(date -Is)"
      echo "CREATED_AT_UNIX=$created"
      echo "MODE=dummy"
      echo "POOL_ID=$pool_id"
      base_identity "$qcow"
      echo "SERIAL_LOG=$serial"
      echo "OVERLAY=$DATA_DIR/overlays/${name}.qcow2"
    } >"$(guest_state_path "$name")"
    overlay=$(create_overlay_from "$name" "$qcow")
    seed_iso=$(make_seed_iso "$name" dummy)
    if ! define_and_start "$name" "$overlay" "$seed_iso" "$mem_mib" "$vcpus"; then
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
      "host HTTP port 80 not reachable as expected" \
      "AdGuard UI not reachable as expected" \
      "gh ok:" \
      "git ok" \
      "no host docker/libvirt sockets visible" \
      "dummy workload complete"
    do
      if ! grep -qF "$needle" "$serial" 2>/dev/null; then
        echo "FAIL: serial missing expected marker: $needle"
        missing=1
      fi
    done
    if [[ -n "${PROBE_URLS_OVERRIDE:-}" ]]; then
      local url
      for url in $PROBE_URLS_OVERRIDE; do
        if ! grep -qF "internal HTTPS ok $url" "$serial" 2>/dev/null; then
          echo "FAIL: serial missing probe marker for $url"
          missing=1
        fi
      done
    fi
    if [[ -n "${CURSOR_CLI_VERSION:-}" ]]; then
      for needle in "Cursor CLI help ok" "Cursor CLI version:"; do
        if ! grep -qF "$needle" "$serial" 2>/dev/null; then
          echo "FAIL: serial missing Cursor marker: $needle"
          missing=1
        fi
      done
    fi
    if [[ "$missing" -ne 0 ]]; then
      echo "FAIL: dummy validation markers incomplete"
      rc=1
    else
      echo "PASS: candidate dummy validation"
      rc=0
    fi
  fi

  cleanup_candidate "${_CI_CANDIDATE_NAME:-}"
  _CI_CANDIDATE_NAME=""
  trap - EXIT
  if [[ -f "$serial" ]]; then
    echo "candidate serial log (retained): $serial"
    echo "  inspect: sudo sed 's/\\x1b\\[[0-9;]*m//g' $serial | tail -n 80"
  fi
  local after_prod
  after_prod=$(list_all_prod_domains | sort | tr '\n' ' ')
  echo "production domains before: ${before_prod:-"(none)"}"
  echo "production domains after : ${after_prod:-"(none)"}"
  if [[ "$before_prod" == "$after_prod" ]]; then
    echo "production spare undisturbed: yes"
  else
    echo "WARNING: production domain set changed during candidate validation"
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
    with_lock recycle_idle "${2:-}"
    ;;
  build-hint)
    echo "Build with: nix build /home/toka/nixosconfig#ci-runner-guest-image -L"
    echo "Then: sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2"
    echo "      sudo ci-runnerctl validate-candidate result/ci-runner-base.qcow2 --pool agent"
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
    pool_id="${2:-ci}"
    with_lock provision_one runner "$pool_id"
    ;;
  dummy)
    name=$(with_lock provision_one dummy ci) || exit $?
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
    if is_managed_domain "$name"; then
      with_lock destroy_guest "$name"
    else
      echo "refusing to destroy non-managed domain: $name"; exit 2
    fi
    write_metrics
    ;;
  destroy-all)
    # Production only; never touches candidate prefixes.
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
  recycle-idle [pool_id]
  build-hint
  reap
  reap-boot
  reconcile
  github-check
  provision [pool_id]
  dummy [timeout_seconds]
  validate-candidate <qcow2> [--pool ID] [--timeout N] [--github-repo OWNER/REPO] [--probe-url URL]... [--allow-capacity-overcommit]
  destroy <domain>
  destroy-all
  metrics
  freshness
EOF
    exit 2
    ;;
esac
