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
    sha256 = "sha256-QQAyaRYLooL/ArAvLPI/Dx7eA+6hI2ogEw9GYmYQDgQ=";
    stripRoot = false;
  };

  jsonFormat = pkgs.formats.json {};

  root-directory = "${cfg.home-directory}/resonite";
  runtime-directory = "${root-directory}/depot";
  headless-directory = "${runtime-directory}/Headless";
  working-manifest-directory = "/var/run/${service-name}/manifest";
  update-manifest-directory = "/var/run/${update-check}/manifest"

  config-filename = "config.json";
  etc-config-file-path = "${service-name}.d/${config-filename}";

  log-directory-path = "/var/log/${service-name}";

  update-check = "${service-name}-update";

  patchelf-command = "${pkgs.patchelf}/bin/patchelf --set-rpath \"${pkgs.libpng}/lib:${pkgs.zlib}/lib:${pkgs.bzip2.out}/lib\"";

  update-check-script = pkgs.writeShellScriptBin update-check ''
    set -euxo pipefail

    ${pkgs.systemd}/bin/systemd-notify --status="Checking manifest..."

    mkdir -p ${update-manifest-directory}

    set +e
    cp -f ${runtime-directory}/manifest_* ${update-manifest-directory}/ 2&>1
    set -e

    if ${pkgs.depotdownloader}/bin/DepotDownloader -username "${cfg.steam-username}" -password "${cfg.steam-password}" -app 2519830 -beta headless -betapassword "${cfg.headless-code}" -dir ${update-manifest-directory} | grep -q "Got manifest"; then
      systemctl restart ${service-name}
    fi
  '';

  init-script-name = "${service-name}-update-and-start";
  init-script = pkgs.writeShellScriptBin init-script-name ''
    set -euxo pipefail

    ${pkgs.systemd}/bin/systemd-notify --status="Checking manifest..."

    mkdir -p ${working-manifest-directory}
    set +e
    cp -f ${runtime-directory}/manifest_*  ${working-manifest-directory}/ 2&>1
    set -e

    if ${pkgs.depotdownloader}/bin/DepotDownloader -username "${cfg.steam-username}" -password "${cfg.steam-password}" -app 2519830 -beta headless -betapassword "${cfg.headless-code}" -dir ${working-manifest-directory} | grep -q "Got manifest"; then
      ${pkgs.systemd}/bin/systemd-notify --status="Clearing old depot..."

      rm -rf ${runtime-directory}
      ${pkgs.systemd}/bin/systemd-notify --status="Downloading new depot..."
      ${pkgs.depotdownloader}/bin/DepotDownloader -username "${cfg.steam-username}" -password "${cfg.steam-password}" -app 2519830 -beta headless -betapassword "${cfg.headless-code}" -dir ${runtime-directory}

      ${pkgs.systemd}/bin/systemd-notify --status="Patching binaries..."
      for dir in ${headless-directory}/runtimes/*/; do
        echo "Entering $dir"
        for file in ''${dir}native/*.so; do
          [ -f "$file" ] || continue  # Skip if it's a literal unexpanded glob
          echo "Patching $file"
          ${patchelf-command} $file
        done
      done

      for file in ${headless-directory}/RuntimeData/*; do
        if [ -d "$file" ]; then
          echo "Skipping directory: $file"
          continue
        fi
        echo "Patching $file"
        chmod 770 $file
        set +e
        ${patchelf-command} $file
        set -e
      done

      ${(if cfg.enable-rml then "${pkgs.systemd}/bin/systemd-notify --status=\"Installing ResoniteModLoader...\"" else "")}
      ${(if cfg.enable-rml then "cp -rf ${rml}/* ${headless-directory}/ && chmod 770 ${headless-directory}/rml_mods && chmod 770 ${headless-directory}/rml_libs && chmod -R 770 ${headless-directory}/rml_libs/ && chmod 770 ${headless-directory}/Libraries && chmod -R 770 ${headless-directory}/Libraries/" else "")}

      cp ${working-manifest-directory}/* ${runtime-directory}/
    fi

    # Loop through and copy each path securely
    ${lib.concatMapStringsSep "\n" (p: ''
      echo "Copying ${toString p} to ${headless-directory}/rml_mods/..."
      cp -f "${toString p}" "${headless-directory}/rml_mods/"
    '') cfg.rml-mods}

    cd ${headless-directory}
    ${pkgs.systemd}/bin/systemd-notify --ready --status="Executing headless..."
    exec ${pkgs.dotnetCorePackages.dotnet_10.runtime}/bin/dotnet ${headless-directory}/Resonite.dll -HeadlessConfig /etc/${etc-config-file-path} ${(if cfg.enable-rml then "-LoadAssembly ${headless-directory}/Libraries/ResoniteModLoader.dll" else "")}
  '';

  config-json = jsonFormat.generate "${service-name}.${config-filename}" (cfg.config-json // {
    dataFolder = "${root-directory}/data";
    cacheFolder = "${root-directory}/cache";
    logsFolder = log-directory-path;
  });
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

    auto-update-interval = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "30m";
      description = ''
        The systemd timer interval for automatic updates.
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

    environment.etc."${etc-config-file-path}".source = config-json;

    systemd = {
      services = {
        "${service-name}" = {
          description = service-name;
          serviceConfig = {
            User = cfg.username;
            Type = "notify";
            NotifyAccess = "all";
            ExecStart = "${init-script}/bin/${init-script-name}";
            TimeoutStartSec = "30m";
            Restart = "always";
            LogsDirectory = service-name;
            WorkingDirectory = cfg.home-directory;
            RuntimeDirectory = service-name;
          };
          restartTriggers = [ 
            config-json
            cfg.enable-rml
            cfg.rml-mods
          ];
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
        };
        "${update-check}" = {
          description = "Update check for ${service-name}";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${update-check-script}/bin/${update-check}";
            User = "root";
            RuntimeDirectory = update-check;
          };
        };  
      };
      timers."${update-check}" = {
        timerConfig = {
          OnUnitActiveSec = cfg.auto-update-interval;
          Unit = "${update-check}.service";
        };
        wantedBy = [ "timers.target" ];
      };
    };
  };
}
