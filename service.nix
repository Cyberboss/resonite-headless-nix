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

  depotdownloader = pkgs.depotdownloader.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or []) ++ [
      (pkgs.fetchpatch {
        name = "add-env-var-support.patch";
        url = "https://github.com/Cyberboss/DepotDownloader/commit/0b0a47a3ace04e772ee0861c2228686fe26716bc.patch";
        hash = "sha256-CV8ttUnS2Gp7Or5K8RrDtHSVz0jp2+dmQQX6p2uHhTc="; 
      })
    ];
  });

  jsonFormat = pkgs.formats.json {};

  root-directory = "${cfg.home-directory}/resonite";
  runtime-directory = "${root-directory}/depot";
  headless-directory = "${runtime-directory}/Headless";
  working-directory = "/var/run/${service-name}";
  working-manifest-directory = "${working-directory}/manifest";
  update-working-directory = "/var/run/${update-check}";
  update-manifest-directory = "${update-working-directory}/manifest";

  config-filename = "${service-name}.config.json";
  runtime-config-path = "${working-directory}/${config-filename}";
  rml-config-path = "${working-directory}/rml_config";

  log-directory-path = "/var/log/${service-name}";

  cmp = "${pkgs.diffutils}/bin/cmp";

  update-check = "${service-name}-update";

  patchelf-command = "${lib.getExe pkgs.patchelf} --set-rpath \"${pkgs.libpng}/lib:${pkgs.zlib}/lib:${pkgs.bzip2.out}/lib\"";

  download-command = "${lib.getExe depotdownloader} -app 2519830 -beta headless -dir ";

  update-check-script = pkgs.writeShellScriptBin update-check ''
    set -aeuo pipefail
    echo "Sourcing ${cfg.depotdownloader-env-file}"
    source ${cfg.depotdownloader-env-file}

    set +a
    set -x
    mkdir -p ${update-manifest-directory}
    
    set +e
    cp -f ${runtime-directory}/manifest_* ${update-manifest-directory}/
    set -e

    find ${update-manifest-directory} -type f -exec md5sum '{}' + | LC_ALL=C sort | md5sum > ${update-working-directory}/manifest-pre.txt
    rm -rf ${update-manifest-directory}
    mkdir ${update-manifest-directory}
    ${download-command} ${update-manifest-directory} -manifest-only
    rm -rf ${update-manifest-directory}/.DepotDownloader
    find ${update-manifest-directory} -type f -exec md5sum '{}' + | LC_ALL=C sort | md5sum > ${update-working-directory}/manifest-post.txt

    if ! ${cmp} -s ${update-working-directory}/manifest-pre.txt ${update-working-directory}/manifest-post.txt; then
      echo "Manifest mismatch!"
      cat ${update-working-directory}/manifest-pre.txt
      cat ${update-working-directory}/manifest-post.txt

      echo "Restarting headless!"
      systemctl restart --no-block ${service-name}
    else
      echo "Up-to-date!"
    fi
  '';

  systemd-notify = "${pkgs.systemd}/bin/systemd-notify";

  init-script-name = "${service-name}-update-and-start";
  init-script = pkgs.writeShellScriptBin init-script-name ''
    set -aeuo pipefail
    
    echo "Sourcing ${cfg.credentials-file}"
    source ${cfg.credentials-file}
    if [[ -z "''${RESONITE_USERNAME}" ]]; then
        echo "ERROR: RESONITE_USERNAME is required in ${cfg.credentials-file} but missing." >&2
        exit 1
    fi
    if [[ -z "''${RESONITE_PASSWORD}" ]]; then
        echo "ERROR: RESONITE_PASSWORD is required in ${cfg.credentials-file} but missing." >&2
        exit 1
    fi

    echo "Sourcing ${cfg.depotdownloader-env-file}"
    source ${cfg.depotdownloader-env-file}

    set +a
    set -x

    ${(if cfg.skip-steam then "" else ''
    ${systemd-notify} --status="Checking manifest..."

    mkdir -p ${working-manifest-directory}
    set +e
    cp -f ${runtime-directory}/manifest_*  ${working-manifest-directory}/
    set -e

    find ${working-manifest-directory} -type f -exec md5sum '{}' + | LC_ALL=C sort | md5sum > ${working-directory}/manifest-pre.txt
    rm -rf ${working-manifest-directory}
    mkdir ${working-manifest-directory}
    ${download-command} ${working-manifest-directory} -manifest-only
    rm -rf ${working-manifest-directory}/.DepotDownloader
    find ${working-manifest-directory} -type f -exec md5sum '{}' + | LC_ALL=C sort | md5sum > ${working-directory}/manifest-post.txt

    if ! ${cmp} -s ${working-directory}/manifest-pre.txt ${working-directory}/manifest-post.txt; then
      echo "Manifest mismatch!"
      ${systemd-notify} --status="Clearing old depot..."

      rm -rf ${runtime-directory}
      ${systemd-notify} --status="Downloading new depot..."
      ${download-command} ${runtime-directory}

      ${systemd-notify} --status="Patching binaries..."
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

      ${(if cfg.enable-rml then "${systemd-notify} --status=\"Installing ResoniteModLoader...\"" else "")}
      ${(if cfg.enable-rml then "cp -rf ${rml}/* ${headless-directory}/ && chmod 770 ${headless-directory}/rml_mods && chmod 770 ${headless-directory}/rml_libs && chmod -R 770 ${headless-directory}/rml_libs/ && rm -rf ${headless-directory}/rml_config && mkdir ${headless-directory}/rml_config && chmod -R 770 ${headless-directory}/rml_config && chmod 770 ${headless-directory}/Libraries && chmod -R 770 ${headless-directory}/Libraries/" else "")}

      cp ${working-manifest-directory}/* ${runtime-directory}/
    fi
    '')}

    # Loop through and copy each path securely
    ${lib.concatMapStringsSep "\n" (p: ''
      echo "Copying ${toString p} to ${headless-directory}/rml_mods/..."
      cp -f "${toString p}" "${headless-directory}/rml_mods/"
    '') cfg.rml-mods}
    ${lib.concatMapStringsSep "\n" (p: ''
      echo "Copying ${toString p} to ${headless-directory}/rml_config/..."
      cp -f "${toString p}" "${headless-directory}/rml_config/"
    '') cfg.rml-configs}

    cd ${headless-directory}
    
    ${(if !cfg.disable-ready-notify then "${systemd-notify} --ready --status=\"Executing headless...\"" else "")}
    ${(if cfg.disable-ready-notify then "${systemd-notify} --status=\"Executing headless...\"" else "")}
    
    ${lib.getExe pkgs.jq} '. + {loginCredential: "$RESONITE_USERNAME", loginPassword: "$RESONITE_PASSWORD"}' ${config-json} > ${runtime-config-path}

    exec ${lib.getExe pkgs.dotnetCorePackages.dotnet_10.runtime} ${headless-directory}/Resonite.dll -HeadlessConfig ${runtime-config-path} ${(if cfg.enable-rml then "-LoadAssembly ${headless-directory}/Libraries/ResoniteModLoader.dll" else "")}
  '';

  config-json = jsonFormat.generate config-filename (cfg.config-json // {
    dataFolder = "${root-directory}/data";
    cacheFolder = "${root-directory}/cache";
    logsFolder = log-directory-path;
    loginCredential = null;
    loginPassword = null;
  });
in
{
  options.services.${service-name} = {
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

    depotdownloader-env-file = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        Path to a file containing the DepotDownloader environment (Currently only supports DEPOT_DOWNLOADER_USERNAME, DEPOT_DOWNLOADER_PASSWORD, and DEPOT_DOWNLOADER_BETA_PASSWORD)
      '';
    };

    skip-steam = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Skips all Steam processes. Useful in cases where you have the latest binaries but rate limiting is occurring
      '';
    };

    auto-update-interval = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "30m";
      description = ''
        The systemd timer interval for automatic updates. See https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#
      '';
    };

    config-json = lib.mkOption {
      type = lib.types.attrs;
      description = ''
        The Config.json layout for the headless. Data and Cache directories are set to the service's home folder. Log directory is in ${log-directory-path}. MUST NOT contain the headless Resonite account credentials. Use credentials-file to inject them at runtime.
      '';
    };

    credentials-file = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        Path to an environment file containing definitions for RESONITE_USERNAME and RESONITE_PASSWORD
      '';
    };

    enable-rml = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable ResoniteModLoader.
      '';
    };

    disable-ready-notify = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to send the systemd ready notification just prior to starting Resonite. Enabling this flag does NOT change the service type from "notify", if you set it, you should have a mod installed that sends the ready notification from within resonite itself.
      '';
    };

    rml-mods = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        A list of ResoniteModLoader mod .dll paths to install.
      '';
    };

    rml-configs = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        A list of ResoniteModLoader mod config .json paths to install.
      '';
    };

    additional-restart-triggers = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        Additional restart triggers for the systemd service
      '';
    };
  };

  config = {
    users = {
      groups."${cfg.groupname}" = { };
      users."${cfg.username}" = {
        isSystemUser = true;
        createHome = true;
        group = cfg.groupname;
        home = cfg.home-directory;
      };
    };

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
            RestartSec="10s";
            RestartMaxDelaySec="1800s";
            RestartSteps="100";
            TimeoutStopSec="15m";
            TimeoutAbortSec="10m";
            LogsDirectory = service-name;
            WorkingDirectory = cfg.home-directory;
            RuntimeDirectory = service-name;
            KillSignal = "SIGINT"; # Resonite doesn't respond to SIGTERM and dies immediately
            WatchdogSignal = "";
            WatchdogFinalKillSignal = "SIGINT";
          };
          restartTriggers = [ 
            config-json
            cfg.enable-rml
            cfg.rml-mods
            cfg.auto-update-interval
          ] ++ cfg.additional-restart-triggers;
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
        };
        "${update-check}" = lib.mkIf !cfg.skip-steam {
          description = "Update check for ${service-name}";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe update-check-script;
            RuntimeDirectory = update-check;
          }
        };
      };
      timers."${update-check}" = {
        timerConfig = {
          OnActiveSec = cfg.auto-update-interval;
          OnUnitActiveSec = cfg.auto-update-interval;
          Unit = "${update-check}.service";
        };
        wantedBy = [ "timers.target" ];
      };
    };
  };
}
