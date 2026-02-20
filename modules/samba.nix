{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Simple SMB file sharing for /bulk
  services.samba = lib.mkIf (secrets.diskIds ? bulkData) {
    enable = true;
    openFirewall = true;

    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = secrets.hostname;
        "netbios name" = secrets.hostname;
        "security" = "user";
        "hosts allow" = "${secrets.ipRangeSamba} 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
      };
      bulk = {
        "path" = "/bulk";
        "read only" = "no";
        "guest ok" = "no";
        "force user" = secrets.username;
        "veto files" =
          "/.DS_Store/._.*/.Trashes/.TemporaryItems/.Spotlight-V100/.fseventsd/.VolumeIcon.icns/.DocumentRevisions-V100/.ql_*/";
        "delete veto files" = "yes";
      };
    };
  };

  # Web Service Discovery (makes share visible in Windows Network)
  services.samba-wsdd.enable = lib.mkIf (secrets.diskIds ? bulkData) true;
}
