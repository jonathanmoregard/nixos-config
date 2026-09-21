{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.services.houseAutomation;
  toml = pkgs.formats.toml { };
  configuredCredentials = (cfg.settings.mqtt or { }).credentials or { };
  credentialVariableKeys = [
    "username_variable"
    "password_variable"
  ];
  safeConfiguredCredentials = lib.filterAttrs (
    name: _: lib.elem name credentialVariableKeys
  ) configuredCredentials;
  settingsWithoutCredentialValues =
    if (cfg.settings.mqtt or { }) ? credentials then
      cfg.settings
      // {
        mqtt = cfg.settings.mqtt // {
          credentials = safeConfiguredCredentials;
        };
      }
    else
      cfg.settings;
  effectiveSettings =
    if cfg.environmentFile == null then
      settingsWithoutCredentialValues
    else
      lib.recursiveUpdate settingsWithoutCredentialValues {
        mqtt.credentials = {
          environment_file = cfg.environmentFile;
          username_variable = safeConfiguredCredentials.username_variable or "MQTT_USERNAME";
          password_variable = safeConfiguredCredentials.password_variable or "MQTT_PASSWORD";
        };
      };
  configFile = toml.generate "house-automation.toml" effectiveSettings;
in
{
  options.services.houseAutomation = {
    enable = mkEnableOption "the house automation MQTT daemon";

    executable = mkOption {
      type = types.str;
      default = "/nix/var/nix/profiles/smarthome/bin/house-automationd";
      description = "Absolute house-automationd executable selected by the dedicated app profile.";
    };

    settings = mkOption {
      inherit (toml) type;
      default = { };
      example = lib.literalExpression ''
        {
          schema_version = 1;
          mqtt = {
            host = "127.0.0.1";
            port = 1883;
            client_id = "house-automation";
          };
          health.bind = "127.0.0.1:9876";
          floors = [ { id = "ground-floor"; } ];
        }
      '';
      description = ''
        Declarative daemon configuration rendered with pkgs.formats.toml.
        Keep credential values out of this attribute set because generated
        configuration is stored in the world-readable Nix store. Use
        services.houseAutomation.environmentFile for MQTT credentials.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/house-automation-mqtt";
      description = ''
        Optional absolute runtime path to an EnvironmentFile containing
        MQTT_USERNAME and MQTT_PASSWORD. Use an agenix-managed runtime path,
        never a path copied into the Nix store.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(configuredCredentials ? environment_file);
        message = "services.houseAutomation.settings.mqtt.credentials.environment_file is not allowed; use services.houseAutomation.environmentFile";
      }
      {
        assertion = lib.all (
          name: lib.elem name credentialVariableKeys
        ) (builtins.attrNames configuredCredentials);
        message = "services.houseAutomation.settings.mqtt.credentials may only set username_variable and password_variable";
      }
      {
        assertion = cfg.environmentFile == null || lib.hasPrefix "/" cfg.environmentFile;
        message = "services.houseAutomation.environmentFile must be an absolute runtime path";
      }
      {
        assertion =
          cfg.environmentFile == null
          || !lib.hasPrefix "${builtins.storeDir}/" cfg.environmentFile;
        message = "services.houseAutomation.environmentFile must not point into the Nix store";
      }
      {
        assertion = lib.hasPrefix "/" cfg.executable && !lib.hasInfix "\n" cfg.executable;
        message = "services.houseAutomation.executable must be an absolute single-line path";
      }
    ];

    environment.etc."house-automation/config.toml".source = configFile;

    users.groups.house-automation = { };
    users.users.house-automation = {
      isSystemUser = true;
      group = "house-automation";
      description = "House automation daemon";
    };

    systemd.services.house-automationd = {
      description = "House automation daemon";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      unitConfig = {
        ConditionFileIsExecutable = cfg.executable;
        StartLimitIntervalSec = 60;
        StartLimitBurst = 5;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.executable} --config ${configFile} --state /var/lib/house-automation/state.sqlite3";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "30s";
        TimeoutStopSec = "20s";

        User = "house-automation";
        Group = "house-automation";
        StateDirectory = "house-automation";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/house-automation";
        UMask = "0077";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ReadWritePaths = [ "/var/lib/house-automation" ];
      }
      // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
