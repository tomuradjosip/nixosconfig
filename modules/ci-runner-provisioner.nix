# systemd units for CI runner reaper + capacity reconciler.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.ciRunner;
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.ci-runner-reaper = {
      description = "Reap stale ephemeral CI runner VMs and overlays";
      after = [
        "libvirtd.service"
        "ci-runner-libvirt-network.service"
        "local-fs.target"
      ];
      wants = [
        "libvirtd.service"
        "ci-runner-libvirt-network.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        # RemainAfterExit keeps this "active (exited)" after its single boot run so
        # that `nixos-rebuild switch` does NOT re-run it. Without this, a oneshot
        # wantedBy multi-user.target is restarted on every switch — which would run
        # the fail-closed reap-boot and destroy the healthy running warm spare.
        RemainAfterExit = true;
        # Boot: treat every leftover CI guest as contaminated.
        ExecStart = "${cfg.package}/bin/ci-runnerctl reap-boot";
      };
    };

    systemd.services.ci-runner-provisioner = {
      description = "Reconcile ephemeral CI runner warm-spare capacity";
      # Order AFTER the boot reaper so that at real boot the fail-closed reap-boot
      # runs first. Do NOT Want it: the reaper is Type=oneshot/RemainAfterExit=no,
      # so a Wants= would re-trigger reap-boot on every timer activation and destroy
      # the healthy warm spare each cycle. After= alone only orders at boot (when the
      # reaper is already in the transaction via its own wantedBy) and is a no-op for
      # periodic timer activations.
      after = [
        "ci-runner-reaper.service"
        "ci-runner-libvirt-network.service"
        "network-online.target"
      ];
      wants = [
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        # When GitHub is disabled, reconcile is a no-op for capacity (still updates metrics).
        ExecStart = "${cfg.package}/bin/ci-runnerctl reconcile";
      };
    };

    systemd.timers.ci-runner-provisioner = {
      description = "Periodically reconcile CI runner capacity";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "2m";
        Persistent = true;
        Unit = "ci-runner-provisioner.service";
      };
    };

    # Periodic soft reap: never kills running guests.
    systemd.services.ci-runner-reaper-soft = {
      description = "Soft-reap shut-off/orphan ephemeral CI runner resources";
      after = [
        "libvirtd.service"
        "ci-runner-libvirt-network.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/ci-runnerctl reap";
      };
    };

    systemd.timers.ci-runner-reaper = {
      description = "Periodically soft-reap stale CI runner resources";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "5m";
        Persistent = true;
        Unit = "ci-runner-reaper-soft.service";
      };
    };

    # Observe-only runner freshness monitor: compares the baked runner version against the
    # latest published GitHub release and exposes node_exporter textfile metrics. It never
    # mutates flake.lock or deploys — the Git repository stays authoritative over inputs.
    systemd.services.ci-runner-freshness = {
      description = "Check ephemeral CI runner version against latest GitHub release";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/ci-runnerctl freshness";
      };
    };

    systemd.timers.ci-runner-freshness = {
      description = "Periodically check CI runner version freshness";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "12h";
        Persistent = true;
        Unit = "ci-runner-freshness.service";
      };
    };
  };
}
