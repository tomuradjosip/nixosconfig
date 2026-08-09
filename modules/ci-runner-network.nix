# Dedicated libvirt NAT network + host firewall isolation for CI guests.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.ciRunner;
  netName = cfg.networkName;
  bridge = cfg.bridgeName;
  gw = cfg.gatewayAddress;
  netLib = import ../packages/ci-runner-network-lib.nix { inherit lib; };

  # 192.168.67.0 -> expect /24
  networkXml = pkgs.writeText "ci-net.xml" ''
    <network>
      <name>${netName}</name>
      <bridge name='${bridge}' stp='on' delay='0'/>
      <forward mode='nat'>
        <nat>
          <port start='1024' end='65535'/>
        </nat>
      </forward>
    ${netLib.renderDnsXml cfg.internalDnsHosts}  <ip address='${gw}' netmask='255.255.255.0'>
        <dhcp>
          <range start='${cfg.dhcpRangeStart}' end='${cfg.dhcpRangeEnd}'/>
        </dhcp>
      </ip>
    </network>
  '';

  fwdAllowRules = netLib.renderFwdAllowRules cfg.subnetCidr cfg.internalAllowTcp;
  hostAllowRules = netLib.renderHostAllowRules cfg.hostAllowTcp;
  gatewayDnsRules = netLib.renderGatewayDnsAllowRules gw;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasSuffix "/24" cfg.subnetCidr;
        message = "services.ciRunner.subnetCidr must be a /24 for v1 network XML generation";
      }
    ];

    # Required for libvirt NAT; scoped by firewall policy below.
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;

    environment.etc."libvirt/qemu/networks/${netName}.xml".source = networkXml;

    systemd.services.ci-runner-libvirt-network = {
      description = "Ensure libvirt CI NAT network ${netName} is defined and active";
      after = [
        "libvirtd.service"
        "network-online.target"
      ];
      wants = [
        "libvirtd.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.libvirt
        pkgs.coreutils
        pkgs.gawk
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # Redefine only when the desired XML content changes (stamp under /data/ci).
      # Avoids tearing down ci-net (and disconnecting idle guests) on every boot.
      script = ''
        set -euo pipefail
        XML=/etc/libvirt/qemu/networks/${netName}.xml
        STAMP=${cfg.dataDir}/state/${netName}.xml.sha256
        mkdir -p ${cfg.dataDir}/state
        HASH=$(sha256sum "$XML" | awk '{print $1}')
        NEED_REDEFINE=0
        if ! virsh net-info ${netName} >/dev/null 2>&1; then
          NEED_REDEFINE=1
        elif [[ ! -f "$STAMP" ]] || [[ "$(cat "$STAMP")" != "$HASH" ]]; then
          NEED_REDEFINE=1
        fi
        if [[ "$NEED_REDEFINE" -eq 1 ]]; then
          if virsh net-info ${netName} >/dev/null 2>&1; then
            virsh net-destroy ${netName} 2>/dev/null || true
            virsh net-undefine ${netName} 2>/dev/null || true
          fi
          virsh net-define "$XML"
          echo "$HASH" >"$STAMP"
        fi
        virsh net-autostart ${netName}
        virsh net-start ${netName} 2>/dev/null || true
      '';
    };

    # Isolation using iptables (this host uses the NixOS iptables firewall, not nftables filterForward).
    networking.firewall.extraCommands = ''
      # --- ci-runner isolation (FORWARD) ---
      iptables -N ci-runner-fwd 2>/dev/null || iptables -F ci-runner-fwd
      iptables -C FORWARD -j ci-runner-fwd 2>/dev/null || iptables -I FORWARD 1 -j ci-runner-fwd
      iptables -A ci-runner-fwd -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
      # Explicit FORWARD exceptions to other private hosts (if any)
      ${fwdAllowRules}
      # Deny RFC1918 destinations from CI subnet (LAN, Podman, other private)
      iptables -A ci-runner-fwd -s ${cfg.subnetCidr} -d 10.0.0.0/8 -j REJECT --reject-with icmp-admin-prohibited
      iptables -A ci-runner-fwd -s ${cfg.subnetCidr} -d 172.16.0.0/12 -j REJECT --reject-with icmp-admin-prohibited
      iptables -A ci-runner-fwd -s ${cfg.subnetCidr} -d 192.168.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
      # Remaining CI traffic (public Internet) falls through to libvirt NAT accepts

      # --- ci-runner isolation (INPUT from CI bridge) ---
      iptables -N ci-runner-in 2>/dev/null || iptables -F ci-runner-in
      iptables -C INPUT -i ${bridge} -j ci-runner-in 2>/dev/null || iptables -I INPUT 1 -i ${bridge} -j ci-runner-in
      iptables -A ci-runner-in -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      # DHCP to libvirt dnsmasq on the CI bridge
      iptables -A ci-runner-in -p udp --dport 67 -j ACCEPT
      # DNS to CI gateway dnsmasq only (explicit internalDnsHosts + public forwarders)
      ${gatewayDnsRules}
      # Narrow host-local TCP exceptions (e.g. Traefik :443 on br0) before reject
      ${hostAllowRules}
      # Deny all other host services (SSH, AdGuard, libvirt, unlisted Traefik ports, etc.)
      iptables -A ci-runner-in -j REJECT --reject-with icmp-admin-prohibited
    '';

    networking.firewall.extraStopCommands = ''
      iptables -D FORWARD -j ci-runner-fwd 2>/dev/null || true
      iptables -F ci-runner-fwd 2>/dev/null || true
      iptables -X ci-runner-fwd 2>/dev/null || true
      iptables -D INPUT -i ${bridge} -j ci-runner-in 2>/dev/null || true
      iptables -F ci-runner-in 2>/dev/null || true
      iptables -X ci-runner-in 2>/dev/null || true
    '';
  };
}
