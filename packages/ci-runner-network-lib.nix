# Pure helpers for CI runner network XML + iptables rule rendering.
# Kept free of module/config evaluation so tests can assert generation deterministically.
{ lib }:

rec {
  # Group [{name,address}] by address for libvirt <dns><host> elements.
  groupDnsHostsByAddress =
    hosts:
    lib.mapAttrs (_addr: entries: map (e: e.name) entries) (
      lib.groupBy (h: h.address) hosts
    );

  renderDnsHostXml =
    hosts:
    let
      grouped = groupDnsHostsByAddress hosts;
      addrs = lib.sort (a: b: a < b) (lib.attrNames grouped);
    in
    lib.concatMapStrings (
      addr:
      let
        names = lib.sort (a: b: a < b) grouped.${addr};
        hostnameXml = lib.concatMapStrings (n: "        <hostname>${n}</hostname>\n") names;
      in
      ''
            <host ip='${addr}'>
        ${hostnameXml}      </host>
      ''
    ) addrs;

  # Always forward public names via public resolvers so CI guests do not inherit
  # LAN/AdGuard/router internal DNS visibility. Static hosts above override.
  renderDnsXml =
    hosts:
    ''
        <dns>
          <forwarder addr='1.1.1.1'/>
          <forwarder addr='8.8.8.8'/>
    ''
    + renderDnsHostXml hosts
    + ''
        </dns>
    '';

  renderFwdAllowRules =
    subnetCidr: allowTcp:
    lib.concatMapStrings (ex: ''
      iptables -A ci-runner-fwd -s ${subnetCidr} -d ${ex.address} -p tcp --dport ${toString ex.port} -j ACCEPT
    '') allowTcp;

  # INPUT exceptions for host-local services reachable on approved addresses
  # (e.g. Traefik on the host LAN IP). Must be inserted before the general reject.
  renderHostAllowRules =
    allowTcp:
    lib.concatMapStrings (ex: ''
      iptables -A ci-runner-in -d ${ex.address} -p tcp --dport ${toString ex.port} -j ACCEPT
    '') allowTcp;

  renderGatewayDnsAllowRules =
    gatewayAddress: ''
      # libvirt dnsmasq on the CI gateway only (not LAN AdGuard on br0)
      iptables -A ci-runner-in -d ${gatewayAddress} -p udp --dport 53 -j ACCEPT
      iptables -A ci-runner-in -d ${gatewayAddress} -p tcp --dport 53 -j ACCEPT
    '';
}
