inputs@{
  config,
  lib,
  pkgs,
  ...
}:

let
  service-name = "resonite-headless";
  cfg = config.services.${service-name};

  rml = pkgs.fetchzip {
    url = "https://github.com/resonite-modding-group/ResoniteModLoader/releases/download/5.0.1/ResoniteModLoader.zip";
    sha256 = "0000000000000000000000000000000000000000000000000000";
  };

  jsonFormat = pkgs.formats.json {};

  init-script-name = "${service-name}-update-and-start";

  runtime-directory = "/run/${service-name}";
  headless-directory = "${runtime-directory}/Headless";

  config-filename = "config.json";
  etc-config-file-path = "${service-name}.d/${config-filename}";

  log-directory-path = "/var/log/${service-name}";

  init-script = pkgs.writeShellScriptBin init-script-name ''
    ${pkgs.depotdownloader}/bin/DepotDownloader -username ${config.steam-username} -password "${config.steam-password}" -app 2519830 -beta headless -betapassword ${config.headless-code} -dir ${runtime-directory}

    for file in ${headless-directory}/runtimes/**/*.so; do
        echo "Patching $file"
        ${pkgs.patchelf}/bin/patchelf --set-rpath "${pkgs.libpng}/lib:${pkgs.zlib}/lib:${pkgs.bzip2}/lib" $file
    done

    ${(if cfg.enable-rml then "cp -r ${rml}/* ${headless-directory}/" else "")}

    # Loop through and copy each path securely
    ${lib.concatMapStringsSep "\n" (p: ''
      echo "Copying ${toString p} to ${headless-directory}/rml_mods/..."
      cp -R "${toString p}" "${headless-directory}/rml_mods/"
    '') cfg.rml-mods}
    exec ${pkgs.dotnetCorePackages.dotnet_10.runtime}/bin/dotnet ${headless-directory}/Resonite.dll -HeadlessConfig /etc/${etc-config-file-path} ${(if cfg.enable-rml then "-LoadAssembly ${headless-directory}/Libraries/ResoniteModLoader.dll" else "")}
  '';
in
{
  ##### interface. here we define the options that users of our service can specify
  options.services.${service-name} = {
    enable = lib.mkEnableOption "";

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
        The Config.json layout for the headless. Data and Cache directories are set to the service's home folder. Log directory is in ${log-directory-path}
      '';
    };

    enable-rml = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable ResoniteModLoader.
      '';
    };

    rml-mods = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        A list of ResoniteModLoader mod .dll paths to install.
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

    environment.etc."${etc-config-file-path}".source = jsonFormat.generate "${service-name}.${config-filename}" (cfg.config-json // {
      dataFolder = "${cfg.home-directory}/data";
      cacheFolder = "${cfg.home-directory}/cache";
      logsFolder = log-directory-path;
    });

    systemd.services.resonite-headless = {
      description = service-name;
      serviceConfig = {
        User = cfg.username;
        Type = "simple";
        NotifyAccess = "all";
        ExecStart = "${init-script}/bin/${init-script-name}";
        Restart = "always";
        RuntimeDirectory = service-name;
        LogsDirectory = service-name;
      };
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ];
    };
  };
}
