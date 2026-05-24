inputs@{
  config,
  lib,
  systemdUtils,
  nixpkgs,
  pkgs,
  writeShellScriptBin,
  ...
}:

let
  service-name = "resonite-headless";
  cfg = config.services.${service-name};

  init-script-name = "${service-name}-update-and-start";

  runtime-directory = "/run/${service-name}";
  headless-directory = "${runtime-directory}/Headless";

  etc-config-file-path = "${service-name}.d/Config.json";

  init-script = pkgs.writeShellScriptBin init-script-name ''
    ${pkgs.depotdownloader}/bin/DepotDownloader -username ${config.steam-username} -password "${config.steam-password}" -app 2519830 -beta headless -betapassword ${config.headless-code} -dir ${runtime-directory}

    for file in ${headless-directory}/runtimes/**/*.so; do
        echo "Patching $file"
        ${pkgs.patchelf}/bin/patchelf --set-rpath "${pkgs.libpng}/lib:${pkgs.zlib}/lib:${pkgs.bzip2}/lib" $file
    done

    exec ${pkgs.dotnetCorePackages.dotnet_10.runtime}/bin/dotnet ${runtime-directory}/Headless/Resonite.dll -HeadlessConfig /etc/${etc-config-file-path}
  '';
in
{
  ##### interface. here we define the options that users of our service can specify
  options.services.${service-name} = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable ${service-name}.
      '';
    };

    username = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = service-name;
      description = ''
        The name of the user used to execute ${service-name}.
      '';
    };

    groupname = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = service-name;
      description = ''
        The name of group the user used to execute ${service-name} will belong to.
      '';
    };

    home-directory = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/home/${service-name}";
      description = ''
        The home directory of ${service-name}. Should be persistent.
      '';
    };

    steam-username = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        The name of the steam account to use.
      '';
    };

    steam-password = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        The password of the steam account to use.
      '';
    };

    headless-code = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        The current Resonite headless code.
      '';
    };

    config-json = lib.mkOption {
      type = lib.types.attrs;
      description = ''
        The Config.json layout for the headless.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users = {
      groups."${cfg.groupname}" = { };
      users."${cfg.username}" = {
        isSystemUser = true;
        createHome = true;
        group = cfg.groupname;
        home = cfg.home-directory;
      };
    };

    environment.etc."${etc-config-file-path}" = (builtins.toJson cfg.config-json);

    systemd.services.resonite-headless = {
      description = service-name;
      serviceConfig = {
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        User = cfg.username;
        Type = "simple";
        NotifyAccess = "all";
        ExecStart = "${init-script}/bin/${init-script-name}";
        Restart = "always";
        RuntimeDirectory = service-name;
      };
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ];
    };
  };
}
