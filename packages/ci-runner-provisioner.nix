{
  pkgs,
  lib,
  dataDir,
  networkName,
  bridgeName,
  domainPrefix,
  runnerLabel,
  desiredCleanCapacity,
  maxGuests,
  guestMemoryMiB,
  guestVcpus,
  lanProbeTarget,
  githubEnable,
  githubOwner,
  githubRepo,
  githubAppId,
  githubInstallationId,
  githubPrivateKeyFile,
  textfileDir,
}:

let
  python = pkgs.python3.withPackages (
    ps: with ps; [
      pyjwt
      cryptography
      requests
    ]
  );

  ghAppToken = pkgs.writeScript "ci-runner-github-app-token" ''
    #!${python}/bin/python3
    import sys, time, pathlib, jwt, requests

    app_id = sys.argv[1]
    installation_id = sys.argv[2]
    key_path = pathlib.Path(sys.argv[3])
    pem = key_path.read_text()
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 8 * 60, "iss": app_id}
    token = jwt.encode(payload, pem, algorithm="RS256")
    if isinstance(token, bytes):
        token = token.decode()
    url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
    r = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=30,
    )
    r.raise_for_status()
    print(r.json()["token"], end="")
  '';

  provisioner = pkgs.writeShellScriptBin "ci-runnerctl" ''
    set -euo pipefail

    DATA_DIR=${lib.escapeShellArg dataDir}
    NETWORK=${lib.escapeShellArg networkName}
    BRIDGE=${lib.escapeShellArg bridgeName}
    PREFIX=${lib.escapeShellArg domainPrefix}
    LABEL=${lib.escapeShellArg runnerLabel}
    DESIRED=${toString desiredCleanCapacity}
    MAX_GUESTS=${toString maxGuests}
    MEM=${toString guestMemoryMiB}
    VCPUS=${toString guestVcpus}
    LAN_PROBE=${lib.escapeShellArg lanProbeTarget}
    GH_ENABLE=${if githubEnable then "1" else "0"}
    GH_OWNER=${lib.escapeShellArg githubOwner}
    GH_REPO=${lib.escapeShellArg githubRepo}
    GH_APP_ID=${lib.escapeShellArg githubAppId}
    GH_INST_ID=${lib.escapeShellArg githubInstallationId}
    GH_KEY=${lib.escapeShellArg githubPrivateKeyFile}
    TEXTFILE_DIR=${lib.escapeShellArg textfileDir}
    BASE_LINK="$DATA_DIR/base/current.qcow2"
    STATE_DIR="$DATA_DIR/state"
    LOCK_FILE="$STATE_DIR/provision.lock"
    STATUS_FILE="$STATE_DIR/status.env"
    METRICS_FILE="$TEXTFILE_DIR/ci_runner.prom"

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.qemu_kvm
        pkgs.libvirt
        pkgs.virt-manager
        pkgs.xorriso
        pkgs.jq
        pkgs.curl
        pkgs.gnugrep
        pkgs.gawk
        pkgs.gnused
        pkgs.findutils
        pkgs.iproute2
        pkgs.systemd
      ]
    }:$PATH

    log() { echo "ci-runnerctl: $*" >&2; logger -t ci-runnerctl "$*" 2>/dev/null || true; }

    ensure_dirs() {
      mkdir -p "$DATA_DIR/base" "$DATA_DIR/overlays" "$DATA_DIR/seeds" "$DATA_DIR/state" "$DATA_DIR/logs"
      chmod 0750 "$DATA_DIR" 2>/dev/null || true
      chmod 0700 "$DATA_DIR/overlays" "$DATA_DIR/seeds" "$DATA_DIR/state" 2>/dev/null || true
    }

    with_lock() {
      ensure_dirs
      mkdir -p "$STATE_DIR"
      exec 9>"$LOCK_FILE"
      # Wait briefly rather than failing fast: at boot/switch the reaper and
      # provisioner may start close together; serialize them instead of TEMPFAILing.
      if ! flock -w 120 9; then
        log "timed out waiting for $LOCK_FILE"
        return 75
      fi
      "$@"
    }

    write_status() {
      local state="$1"
      shift
      {
        echo "STATE=$state"
        echo "UPDATED_AT=$(date -Is)"
        for kv in "$@"; do
          echo "$kv"
        done
      } >"$STATUS_FILE.tmp"
      mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
    }

    read_status_var() {
      local key="$1"
      if [[ -f "$STATUS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATUS_FILE"
        eval "echo \"\''${$key-}\""
      fi
    }

    write_metrics() {
      mkdir -p "$TEXTFILE_DIR"
      local clean=0 active=0 overlay_bytes=0
      local state="none"
      if [[ -f "$STATUS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATUS_FILE" || true
        state="''${STATE:-none}"
      fi
      case "$state" in
        registered|idle) clean=1; active=1 ;;
        provisioning|busy|unknown|teardown) active=1 ;;
        none|"") active=0; clean=0 ;;
      esac
      # Count live CI domains
      local doms
      doms=$(virsh list --name 2>/dev/null | grep "^''${PREFIX}" || true)
      if [[ -n "$doms" ]]; then
        active=1
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
        echo '# HELP ci_runner_clean_capacity Clean idle ephemeral runners available'
        echo '# TYPE ci_runner_clean_capacity gauge'
        echo "ci_runner_clean_capacity $clean"
        echo '# HELP ci_runner_guest_active CI guest domains currently present'
        echo '# TYPE ci_runner_guest_active gauge'
        echo "ci_runner_guest_active $active"
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
        echo "ci_runner_overlay_bytes ''${overlay_bytes:-0}"
      } >"$tmp"
      mv -f "$tmp" "$METRICS_FILE"
    }

    bump_counter() {
      local file="$1"
      local cur=0
      [[ -f "$file" ]] && cur=$(cat "$file")
      echo $((cur + 1)) >"$file"
    }

    require_base() {
      if [[ ! -e "$BASE_LINK" ]]; then
        log "missing base image link $BASE_LINK — run: ci-runnerctl install-base <qcow2>"
        return 1
      fi
    }

    destroy_guest() {
      local name="$1"
      log "destroying guest $name"
      write_status teardown "GUEST=$name"
      virsh destroy "$name" 2>/dev/null || true
      # Never autostart CI guests; undefine without nvram unless present
      virsh undefine "$name" --remove-all-storage 2>/dev/null \
        || virsh undefine "$name" 2>/dev/null \
        || true
      # Overlays/seeds named after guest
      rm -f "$DATA_DIR/overlays/''${name}.qcow2" \
            "$DATA_DIR/seeds/''${name}.iso" \
            "$DATA_DIR/seeds/''${name}.dir"/* 2>/dev/null || true
      rmdir "$DATA_DIR/seeds/''${name}.dir" 2>/dev/null || true
      # Clear status if it pointed at this guest
      if [[ -f "$STATUS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATUS_FILE" || true
        if [[ "''${GUEST-}" == "$name" ]]; then
          write_status none
        fi
      fi
    }

    list_ci_domains() {
      virsh list --all --name 2>/dev/null | grep "^''${PREFIX}" || true
    }

    reap_orphans() {
      # mode=boot → destroy every CI guest (post-reboot / fail-closed)
      # mode=soft (default) → destroy only non-running guests + orphan disks
      local mode="''${1:-soft}"
      log "reaping stale CI resources mode=$mode"
      local cleaned=0
      local d state
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
      # Orphan overlays/seeds without domains (always)
      local f base
      if [[ -d "$DATA_DIR/overlays" ]]; then
        for f in "$DATA_DIR/overlays"/''${PREFIX}*.qcow2; do
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
        for f in "$DATA_DIR/seeds"/''${PREFIX}*.iso; do
          [[ -e "$f" ]] || continue
          base=$(basename "$f" .iso)
          if ! virsh dominfo "$base" >/dev/null 2>&1; then
            log "reaper: removing orphan seed $f"
            rm -f "$f"
            cleaned=$((cleaned + 1))
          fi
        done
        for f in "$DATA_DIR/seeds"/''${PREFIX}*.dir; do
          [[ -d "$f" ]] || continue
          base=$(basename "$f" .dir)
          if ! virsh dominfo "$base" >/dev/null 2>&1; then
            log "reaper: removing orphan seed dir $f"
            rm -rf "$f"
            cleaned=$((cleaned + 1))
          fi
        done
      fi
      if [[ "$cleaned" -gt 0 ]]; then
        local cur=0
        [[ -f "$STATE_DIR/orphan_cleanup" ]] && cur=$(cat "$STATE_DIR/orphan_cleanup")
        echo $((cur + cleaned)) >"$STATE_DIR/orphan_cleanup"
      fi
      # Only clear status when no CI guests remain
      if [[ -z "$(list_ci_domains)" ]]; then
        write_status none
      fi
      write_metrics
      log "reaper done cleaned=$cleaned"
    }

    make_seed_iso() {
      local name="$1"
      local mode="$2"
      local seed_dir="$DATA_DIR/seeds/''${name}.dir"
      local seed_iso="$DATA_DIR/seeds/''${name}.iso"
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
      echo "$seed_iso"
    }

    create_overlay() {
      local name="$1"
      local overlay="$DATA_DIR/overlays/''${name}.qcow2"
      mkdir -p "$DATA_DIR/overlays"
      rm -f "$overlay"
      qemu-img create -f qcow2 -b "$BASE_LINK" -F qcow2 "$overlay" >/dev/null
      echo "$overlay"
    }

    define_and_start() {
      local name="$1"
      local overlay="$2"
      local seed_iso="$3"
      local serial_log="$DATA_DIR/logs/''${name}.serial.log"
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
      # Never persist autostart for CI guests
      virsh autostart --disable "$name" 2>/dev/null || true
      # Confirm running
      local state
      state=$(virsh domstate "$name" 2>/dev/null | tr -d '[:space:]' || echo missing)
      if [[ "$state" != "running" ]]; then
        log "guest $name not running after virt-install (state=$state)"
        return 1
      fi
      log "serial log: $serial_log"
    }

    fetch_registration_token() {
      if [[ "$GH_ENABLE" != "1" ]]; then
        log "GitHub registration disabled"
        return 1
      fi
      if [[ ! -f "$GH_KEY" ]]; then
        log "missing GitHub App private key at $GH_KEY"
        return 1
      fi
      local inst_token reg_json token
      inst_token=$(${ghAppToken} "$GH_APP_ID" "$GH_INST_ID" "$GH_KEY") || {
        log "failed to mint installation token (check appId/installationId/key)"
        return 1
      }
      [[ -n "$inst_token" ]] || { log "empty installation token"; return 1; }
      reg_json=$(curl -fsS -X POST \
        -H "Authorization: Bearer $inst_token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/''${GH_OWNER}/''${GH_REPO}/actions/runners/registration-token") || {
        log "registration-token request failed (App needs Administration: read/write on the repo)"
        return 1
      }
      token=$(echo "$reg_json" | jq -r '.token // empty')
      if [[ -z "$token" ]]; then
        log "registration-token response had no .token"
        return 1
      fi
      echo "$token"
    }

    github_check() {
      # Validates credentials/permissions regardless of github.enable so you can
      # confirm setup BEFORE flipping the flag (avoids auto-provisioning a runner
      # during validation). Registers nothing.
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
      inst_token=$(${ghAppToken} "$GH_APP_ID" "$GH_INST_ID" "$GH_KEY") || {
        echo "FAIL: could not mint installation token (bad appId/installationId/key, or App not installed on repo)"
        return 1
      }
      [[ -n "$inst_token" ]] || { echo "FAIL: empty installation token"; return 1; }
      echo "OK  : minted installation access token"
      local runners n
      runners=$(curl -fsS \
        -H "Authorization: Bearer $inst_token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$GH_OWNER/$GH_REPO/actions/runners") || {
        echo "FAIL: cannot list repo runners (App needs Administration: read/write)"
        return 1
      }
      n=$(echo "$runners" | jq -r '.total_count // 0')
      echo "OK  : listed repo self-hosted runners (currently registered: $n)"
      local reg
      reg=$(curl -fsS -X POST \
        -H "Authorization: Bearer $inst_token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$GH_OWNER/$GH_REPO/actions/runners/registration-token") || {
        echo "FAIL: cannot mint registration-token (App needs Administration: read/write)"
        return 1
      }
      if [[ -n "$(echo "$reg" | jq -r '.token // empty')" ]]; then
        echo "OK  : minted a registration token (discarded; NO runner was registered)"
      else
        echo "FAIL: registration-token response had no token"
        return 1
      fi
      echo "PASS: credentials valid — safe to provision a runner guest."
    }

    delete_stale_github_runners() {
      if [[ "$GH_ENABLE" != "1" ]] || [[ ! -f "$GH_KEY" ]]; then
        return 0
      fi
      local inst_token
      inst_token=$(${ghAppToken} "$GH_APP_ID" "$GH_INST_ID" "$GH_KEY" || true)
      [[ -n "''${inst_token:-}" ]] || return 0
      local runners
      runners=$(curl -fsS \
        -H "Authorization: Bearer $inst_token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/''${GH_OWNER}/''${GH_REPO}/actions/runners" || true)
      [[ -n "$runners" ]] || return 0
      echo "$runners" | jq -r --arg p "$PREFIX" '.runners[]? | select(.name|startswith($p)) | "\(.id) \(.name) \(.status)"' \
        | while read -r id name status; do
            # Remove offline platform runners; online ones belonging to live guests are kept.
            if [[ "$status" == "offline" ]]; then
              log "deleting stale GitHub runner $name ($id)"
              curl -fsS -X DELETE \
                -H "Authorization: Bearer $inst_token" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/''${GH_OWNER}/''${GH_REPO}/actions/runners/$id" \
                >/dev/null || true
            fi
          done
    }

    guest_count() {
      list_ci_domains | grep -c . || true
    }

    provision_one() {
      local mode="''${1:-runner}"
      require_base
      local count
      count=$(guest_count)
      if [[ "$count" -ge "$MAX_GUESTS" ]]; then
        log "max guests reached ($count >= $MAX_GUESTS)"
        return 0
      fi
      local name overlay seed_iso token repo_url
      name="''${PREFIX}$(date +%Y%m%d%H%M%S)-$RANDOM"
      write_status provisioning "GUEST=$name" "MODE=$mode"
      log "provisioning $name mode=$mode"
      overlay=$(create_overlay "$name")
      if [[ "$mode" == "runner" ]]; then
        token=$(fetch_registration_token) || {
          bump_counter "$STATE_DIR/provision_failures"
          destroy_guest "$name"
          write_status none
          write_metrics
          return 1
        }
        repo_url="https://github.com/''${GH_OWNER}/''${GH_REPO}"
        seed_iso=$(make_seed_iso "$name" runner "$repo_url" "$token")
        # Drop token from shell as soon as seed is written
        unset token
      else
        seed_iso=$(make_seed_iso "$name" dummy)
      fi
      if ! define_and_start "$name" "$overlay" "$seed_iso"; then
        log "failed to start $name"
        bump_counter "$STATE_DIR/provision_failures"
        destroy_guest "$name"
        write_status none
        write_metrics
        return 1
      fi
      date +%s >"$STATE_DIR/provision_success_ts"
      if [[ "$mode" == "dummy" ]]; then
        write_status busy "GUEST=$name" "MODE=dummy"
      else
        write_status registered "GUEST=$name" "MODE=runner"
      fi
      write_metrics
      log "provisioned $name"
      echo "$name"
    }

    reconcile() {
      log "reconcile start"
      # If a guest exists but is shut off, it is contaminated — destroy.
      local d state
      for d in $(list_ci_domains); do
        state=$(virsh domstate "$d" 2>/dev/null || echo missing)
        case "$state" in
          running) ;;
          *)
            log "guest $d state=$state — destroying"
            destroy_guest "$d" || bump_counter "$STATE_DIR/teardown_failures"
            ;;
        esac
      done
      count=$(guest_count)
      if [[ "$count" -gt "$MAX_GUESTS" ]]; then
        log "too many guests ($count); destroying extras"
        for d in $(list_ci_domains | tail -n +$((MAX_GUESTS + 1))); do
          destroy_guest "$d" || true
        done
        count=$(guest_count)
      fi
      if [[ "$GH_ENABLE" == "1" ]]; then
        delete_stale_github_runners || true
        if [[ "$count" -lt "$DESIRED" ]]; then
          provision_one runner || true
        fi
      else
        log "GitHub disabled; not provisioning warm spare"
      fi
      write_metrics
      log "reconcile done"
    }

    wait_dummy_and_destroy() {
      local name="$1"
      local timeout="''${2:-180}"
      local i=0
      local state
      log "waiting for dummy guest $name to shut down (timeout ''${timeout}s)"
      while [[ $i -lt $timeout ]]; do
        if ! virsh dominfo "$name" >/dev/null 2>&1; then
          log "guest $name gone"
          destroy_guest "$name"
          write_metrics
          return 0
        fi
        state=$(virsh domstate "$name" 2>/dev/null | tr -d '[:space:]' || echo missing)
        if [[ "$state" == "missing" || "$state" == "shutoff" ]]; then
          log "guest $name stopped (state=$state)"
          destroy_guest "$name"
          write_metrics
          return 0
        fi
        sleep 2
        i=$((i + 2))
      done
      log "timeout waiting for $name; forcing destroy"
      destroy_guest "$name" || bump_counter "$STATE_DIR/teardown_failures"
      write_metrics
      return 1
    }

    cmd="''${1:-}"
    case "$cmd" in
      status)
        echo "DATA_DIR=$DATA_DIR"
        echo "BASE_LINK=$BASE_LINK -> $(readlink -f "$BASE_LINK" 2>/dev/null || echo missing)"
        echo "NETWORK=$NETWORK BRIDGE=$BRIDGE"
        echo "GH_ENABLE=$GH_ENABLE"
        echo "--- status.env ---"
        cat "$STATUS_FILE" 2>/dev/null || echo "(none)"
        echo "--- domains ---"
        list_ci_domains || echo "(none)"
        write_metrics
        ;;
      install-base)
        src="''${2:-}"
        [[ -n "$src" && -f "$src" ]] || { echo "usage: ci-runnerctl install-base <path-to-qcow2>"; exit 2; }
        ensure_dirs
        dest="$DATA_DIR/base/ci-runner-base-$(date +%Y%m%d%H%M%S).qcow2"
        cp -f "$src" "$dest"
        chmod 0444 "$dest"
        ln -sfn "$dest" "$BASE_LINK"
        log "installed base $dest as current"
        ;;
      build-hint)
        echo "Build with: nix build /home/toka/nixosconfig#ci-runner-guest-image -L"
        echo "Then: sudo ci-runnerctl install-base result/ci-runner-base.qcow2"
        ;;
      reap)
        # Soft periodic reap (default): do not kill running guests.
        with_lock reap_orphans soft
        ;;
      reap-boot)
        # Aggressive boot reap: every CI guest is contaminated after host reboot.
        with_lock reap_orphans boot
        ;;
      reconcile)
        with_lock reconcile
        ;;
      github-check)
        # Non-destructive: validates App credentials + permissions. Registers nothing.
        github_check
        ;;
      provision)
        with_lock provision_one runner
        ;;
      dummy)
        name=$(with_lock provision_one dummy) || exit $?
        name=$(echo "$name" | tail -n1 | tr -d '[:space:]')
        [[ -n "$name" ]] || { echo "dummy provision failed"; exit 1; }
        wait_dummy_and_destroy "$name" "''${2:-240}"
        ;;
      destroy)
        name="''${2:-}"
        [[ -n "$name" ]] || { echo "usage: ci-runnerctl destroy <domain>"; exit 2; }
        case "$name" in
          ''${PREFIX}*) with_lock destroy_guest "$name" ;;
          *) echo "refusing to destroy non-CI domain: $name"; exit 2 ;;
        esac
        write_metrics
        ;;
      destroy-all)
        with_lock reap_orphans boot
        ;;
      metrics)
        write_metrics
        cat "$METRICS_FILE"
        ;;
      *)
        cat <<EOF
usage: ci-runnerctl <command>
  status
  install-base <qcow2>
  build-hint
  reap
  reap-boot
  reconcile
  github-check
  provision
  dummy [timeout_seconds]
  destroy <domain>
  destroy-all
  metrics
EOF
        exit 2
        ;;
    esac
  '';
in
pkgs.symlinkJoin {
  name = "ci-runner-provisioner";
  paths = [ provisioner ];
}
