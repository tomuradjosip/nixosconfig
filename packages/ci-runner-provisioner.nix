{
  pkgs,
  lib,
  dataDir,
  networkName,
  bridgeName,
  domainPrefix,
  candidatePrefix ? "ci-candidate-",
  runnerLabel,
  runnerVersion ? "",
  desiredIdleCapacity,
  maxGuests,
  guestMemoryMiB,
  guestVcpus,
  lanProbeTarget,
  provisioningGraceSec ? 300,
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

  poolPlanner = pkgs.writeScript "ci-runner-pool" (
    ''
      #!${python}/bin/python3
    ''
    + builtins.readFile ./ci-runner-pool.py
  );

  binPath = lib.makeBinPath [
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
    pkgs.gh
  ];

  provisioner = pkgs.runCommand "ci-runnerctl" { } ''
    mkdir -p $out/bin
    substitute ${./ci-runnerctl.sh} $out/bin/ci-runnerctl \
      --subst-var-by bash ${lib.escapeShellArg "${pkgs.bash}/bin/bash"} \
      --subst-var-by dataDir ${lib.escapeShellArg dataDir} \
      --subst-var-by networkName ${lib.escapeShellArg networkName} \
      --subst-var-by bridgeName ${lib.escapeShellArg bridgeName} \
      --subst-var-by domainPrefix ${lib.escapeShellArg domainPrefix} \
      --subst-var-by candidatePrefix ${lib.escapeShellArg candidatePrefix} \
      --subst-var-by runnerLabel ${lib.escapeShellArg runnerLabel} \
      --subst-var-by runnerVersion ${lib.escapeShellArg runnerVersion} \
      --subst-var-by desiredIdleCapacity ${lib.escapeShellArg (toString desiredIdleCapacity)} \
      --subst-var-by maxGuests ${lib.escapeShellArg (toString maxGuests)} \
      --subst-var-by guestMemoryMiB ${lib.escapeShellArg (toString guestMemoryMiB)} \
      --subst-var-by guestVcpus ${lib.escapeShellArg (toString guestVcpus)} \
      --subst-var-by lanProbeTarget ${lib.escapeShellArg lanProbeTarget} \
      --subst-var-by provisioningGraceSec ${lib.escapeShellArg (toString provisioningGraceSec)} \
      --subst-var-by githubEnable ${lib.escapeShellArg (if githubEnable then "1" else "0")} \
      --subst-var-by githubOwner ${lib.escapeShellArg githubOwner} \
      --subst-var-by githubRepo ${lib.escapeShellArg githubRepo} \
      --subst-var-by githubAppId ${lib.escapeShellArg githubAppId} \
      --subst-var-by githubInstallationId ${lib.escapeShellArg githubInstallationId} \
      --subst-var-by githubPrivateKeyFile ${lib.escapeShellArg githubPrivateKeyFile} \
      --subst-var-by textfileDir ${lib.escapeShellArg textfileDir} \
      --subst-var-by poolBin ${lib.escapeShellArg poolPlanner} \
      --subst-var-by ghAppTokenBin ${lib.escapeShellArg ghAppToken} \
      --subst-var-by path ${lib.escapeShellArg binPath}
    chmod +x $out/bin/ci-runnerctl
  '';
in
pkgs.symlinkJoin {
  name = "ci-runner-provisioner";
  paths = [ provisioner ];
}
