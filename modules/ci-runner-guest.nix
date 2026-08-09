# NixOS module for the disposable CI runner guest image.
# Built into a qcow2 base via packages/ci-runner-guest-image.nix.
# Must not contain host secrets, GitHub App keys, or application toolchains.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  runnerPkg = pkgs.github-runner;
  lifecycleScript = pkgs.writeShellScript "ci-runner-lifecycle" ''
    set -euo pipefail
    SEED_DIR=/run/ci-seed
    SEED_ENV="$SEED_DIR/ci-seed.env"
    LOG_TAG=ci-runner-lifecycle

    # Plain echo; systemd StandardOutput=journal+console mirrors to /dev/console (ttyS0).
    log() {
      echo "$LOG_TAG: $*"
    }

    poweroff_now() {
      log "requesting poweroff"
      ${pkgs.systemd}/bin/systemctl poweroff --force --force || true
    }
    trap poweroff_now EXIT

    log "lifecycle started"

    # Wait for seed ISO (cdrom may appear after virtio root)
    for i in $(seq 1 30); do
      if [[ -f "$SEED_ENV" ]]; then
        break
      fi
      mkdir -p "$SEED_DIR"
      for dev in /dev/disk/by-label/CI_SEED /dev/sr0 /dev/cdrom; do
        if [[ -e "$dev" ]]; then
          ${pkgs.util-linux}/bin/mount -o ro "$dev" "$SEED_DIR" 2>/dev/null || true
        fi
      done
      log "waiting for seed ($i/30)"
      sleep 1
    done

    if [[ ! -f "$SEED_ENV" ]]; then
      log "no seed present after wait; devices:"
      ${pkgs.coreutils}/bin/ls -la /dev/disk/by-label/ 2>/dev/null || true
      ${pkgs.util-linux}/bin/lsblk -f 2>/dev/null || true
      exit 1
    fi

    log "seed found at $SEED_ENV"

    set -a
    # shellcheck disable=SC1090
    source "$SEED_ENV"
    set +a

    MODE="''${MODE:-dummy}"
    log "mode=$MODE"

    case "$MODE" in
      dummy)
        MARKER=/var/lib/ci-dummy-marker
        mkdir -p /var/lib
        echo "dummy-marker-$(date -Is)-$RANDOM" > "$MARKER"
        log "wrote marker $MARKER"
        log "public HTTPS probe"
        ${pkgs.curl}/bin/curl -fsS --max-time 20 https://example.com/ >/dev/null
        log "public HTTPS ok"
        log "DNS probe"
        ${pkgs.host}/bin/host example.com >/dev/null
        log "DNS ok"
        LAN_TARGET="''${LAN_PROBE_TARGET:-192.168.10.7}"
        log "LAN probe (expect failure) to $LAN_TARGET"
        if ${pkgs.curl}/bin/curl -fsS --connect-timeout 3 --max-time 5 "http://''${LAN_TARGET}/" >/dev/null 2>&1; then
          log "ERROR: LAN HTTP reachable — isolation failed"
          exit 2
        fi
        log "LAN HTTP blocked as expected"
        if ${pkgs.iputils}/bin/ping -c 1 -W 2 "$LAN_TARGET" >/dev/null 2>&1; then
          log "ERROR: LAN ping succeeded — isolation failed"
          exit 2
        fi
        log "LAN ping blocked as expected"
        if ${pkgs.coreutils}/bin/timeout 3 ${pkgs.bash}/bin/bash -c "echo >/dev/tcp/''${LAN_TARGET}/22" 2>/dev/null; then
          log "ERROR: host SSH port appears open from guest"
          exit 2
        fi
        log "host SSH not reachable as expected"
        log "dummy workload complete"
        ;;
      runner)
        : "''${REPO_URL:?REPO_URL required}"
        : "''${REGISTRATION_TOKEN:?REGISTRATION_TOKEN required}"
        : "''${RUNNER_NAME:?RUNNER_NAME required}"
        RUNNER_LABELS="''${RUNNER_LABELS:-nixos-ephemeral-ci,self-hosted,Linux,X64}"
        WORK_DIR=/var/lib/ci-github-runner
        rm -rf "$WORK_DIR"
        mkdir -p "$WORK_DIR/work" "$WORK_DIR/state"
        export RUNNER_ALLOW_RUNASROOT=1
        export RUNNER_ROOT="$WORK_DIR/state"
        export HOME=/root
        log "configuring ephemeral runner name=$RUNNER_NAME"
        # --disableupdate is required on NixOS: the runner lives in the immutable
        # /nix/store, so GitHub's in-place auto-update (download + tar -xzf over its
        # own dir) fails and kills the listener. The runner is updated by rebuilding
        # this base image (nixpkgs github-runner), not by GitHub's self-updater.
        ${runnerPkg}/bin/Runner.Listener configure \
          --unattended \
          --work "$WORK_DIR/work" \
          --url "$REPO_URL" \
          --token "$REGISTRATION_TOKEN" \
          --name "$RUNNER_NAME" \
          --labels "$RUNNER_LABELS" \
          --ephemeral \
          --disableupdate
        log "starting runner (at most one job)"
        set +e
        ${runnerPkg}/bin/Runner.Listener run
        rc=$?
        set -e
        log "runner exited rc=$rc"
        exit "$rc"
        ;;
      *)
        log "unknown MODE=$MODE"
        exit 1
        ;;
    esac
  '';
in
{
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";
  # Order matters: the LAST console= becomes /dev/console. Keep ttyS0 last so
  # systemd service output (StandardOutput=console) lands on the captured serial.
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];
  boot.growPartition = true;
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "sd_mod"
    "sr_mod"
    "iso9660"
  ];
  boot.initrd.kernelModules = [
    "virtio_pci"
    "virtio_blk"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  fileSystems."/run/ci-seed" = {
    device = "/dev/disk/by-label/CI_SEED";
    fsType = "iso9660";
    options = [
      "ro"
      "nofail"
      "x-systemd.device-timeout=30s"
    ];
  };

  networking = {
    hostName = "ci-runner";
    useDHCP = true;
    firewall.enable = true;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    dhcpcd.extraConfig = ''
      nohook resolv.conf
    '';
  };

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  users.mutableUsers = false;
  users.allowNoPasswordLogin = true; # disposable VM: serial console only, SSH disabled
  users.users.root.hashedPassword = "!";

  environment.systemPackages = with pkgs; [
    git
    cacert
    curl
    wget
    gnutar
    gzip
    unzip
    xz
    jq
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    bash
    host # DNS lookup utility (bind)
    iputils
    github-runner
    gcc
    gnumake
    pkg-config
  ];

  virtualisation.docker.enable = lib.mkForce false;
  virtualisation.podman.enable = lib.mkForce false;
  services.openssh.enable = false;

  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=64M
  '';

  systemd.services.ci-runner-lifecycle = {
    description = "Ephemeral CI runner / dummy lifecycle";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "run-ci\\x2dseed.mount"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = with pkgs; [
      coreutils
      bash
      curl
      git
      jq
      github-runner
      host
      iputils
      cacert
      util-linux
    ];
    serviceConfig.ExecStart = "${lifecycleScript}";
  };

  system.stateVersion = "25.05";
}
