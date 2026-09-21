{ pkgs, inputs }:

let
  inherit (pkgs) lib;
  stableExecutable = "/opt/house-automation/bin/house-automationd";
  environmentFile = "/run/agenix/house-automation-mqtt";
  secretLiteral = "must-not-enter-the-store";
  module = ../modules/nixos/house-automation-service.nix;

  eval = service:
    inputs.nixpkgs.lib.nixosSystem {
      inherit pkgs;
      modules = [
        module
        {
          documentation.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.11";
          services.houseAutomation = {
            enable = true;
            executable = stableExecutable;
            settings = { };
            environmentFile = null;
          }
          // service;
        }
      ];
    };

  configFor = service: (eval service).config;
  assertionsFor = service: (configFor service).assertions;
  hasAssertion = expected: message: service:
    lib.any (item: item.assertion == expected && item.message == message)
      (assertionsFor service);

  directCredentialPathMessage =
    "services.houseAutomation.settings.mqtt.credentials.environment_file is not allowed; use services.houseAutomation.environmentFile";
  credentialKeysMessage =
    "services.houseAutomation.settings.mqtt.credentials may only set username_variable and password_variable";
  absoluteEnvironmentFileMessage =
    "services.houseAutomation.environmentFile must be an absolute runtime path";
  storeEnvironmentFileMessage =
    "services.houseAutomation.environmentFile must not point into the Nix store";
  executableMessage =
    "services.houseAutomation.executable must be an absolute single-line path";

  acceptedService = {
    environmentFile = environmentFile;
    settings = {
      schema_version = 1;
      mqtt = {
        host = "127.0.0.1";
        credentials = {
          username_variable = "HOUSE_MQTT_USERNAME";
          password_variable = "HOUSE_MQTT_PASSWORD";
        };
      };
    };
  };
  secretBearingService = {
    settings.mqtt.credentials.password = secretLiteral;
  };
  cfg = configFor acceptedService;
  unit = cfg.systemd.services.house-automationd;
  service = unit.serviceConfig;
  configToml = cfg.environment.etc."house-automation/config.toml".source;
  rejectedConfigToml =
    (configFor secretBearingService).environment.etc."house-automation/config.toml".source;
in
assert hasAssertion false directCredentialPathMessage {
  settings.mqtt.credentials.environment_file = "/run/credentials/house-automation";
};
assert hasAssertion false credentialKeysMessage secretBearingService;
assert hasAssertion false absoluteEnvironmentFileMessage {
  environmentFile = "relative/house-automation.env";
};
assert hasAssertion false storeEnvironmentFileMessage {
  environmentFile = "${builtins.storeDir}/house-automation.env";
};
assert hasAssertion true directCredentialPathMessage acceptedService;
assert hasAssertion true credentialKeysMessage acceptedService;
assert hasAssertion true absoluteEnvironmentFileMessage acceptedService;
assert hasAssertion true storeEnvironmentFileMessage acceptedService;
assert hasAssertion false executableMessage { executable = "relative/house-automationd"; };
assert hasAssertion false executableMessage { executable = "${stableExecutable}\n--unsafe"; };
assert hasAssertion true executableMessage acceptedService;
assert !(lib.any (package: lib.hasInfix "house-automation" (lib.getName package)) cfg.environment.systemPackages);
assert service.ExecStart == "${stableExecutable} --config ${configToml} --state /var/lib/house-automation/state.sqlite3";
assert unit.unitConfig.ConditionFileIsExecutable == stableExecutable;
assert service.EnvironmentFile == environmentFile;
assert cfg.users.groups ? house-automation;
assert cfg.users.users.house-automation.isSystemUser;
assert service.User == "house-automation";
assert service.Group == "house-automation";
assert service.StateDirectory == "house-automation";
assert service.StateDirectoryMode == "0700";
assert service.WorkingDirectory == "/var/lib/house-automation";
assert service.UMask == "0077";
assert service.Restart == "on-failure";
assert service.RestartSec == "5s";
assert service.TimeoutStartSec == "30s";
assert service.TimeoutStopSec == "20s";
assert service.NoNewPrivileges;
assert service.ProtectSystem == "strict";
assert service.ProtectHome;
assert service.PrivateTmp;
assert service.PrivateDevices;
assert service.ProtectKernelTunables;
assert service.ProtectKernelModules;
assert service.ProtectControlGroups;
assert service.ProtectClock;
assert service.ProtectHostname;
assert service.LockPersonality;
assert service.RestrictRealtime;
assert service.RestrictSUIDSGID;
assert service.RemoveIPC;
assert service.RestrictAddressFamilies == [ "AF_UNIX" "AF_INET" "AF_INET6" ];
assert service.CapabilityBoundingSet == "";
assert service.AmbientCapabilities == "";
assert service.ReadWritePaths == [ "/var/lib/house-automation" ];
assert unit.unitConfig.StartLimitIntervalSec == 60;
assert unit.unitConfig.StartLimitBurst == 5;
assert !(
  lib.hasInfix secretLiteral (builtins.toJSON {
    inherit (service) ExecStart EnvironmentFile;
    inherit (unit) unitConfig;
  })
);
pkgs.runCommand "house-automation-service-contract"
  {
    inherit
      configToml
      rejectedConfigToml
      stableExecutable
      environmentFile
      secretLiteral
      ;
  }
  ''
    test -f "$configToml"
    grep -F 'environment_file = "'"$environmentFile"'"' "$configToml"
    grep -F 'username_variable = "HOUSE_MQTT_USERNAME"' "$configToml"
    grep -F 'password_variable = "HOUSE_MQTT_PASSWORD"' "$configToml"
    if grep -F "$secretLiteral" "$configToml"; then
      echo "credential literal leaked into generated TOML" >&2
      exit 1
    fi
    if grep -E '(password|secret)[[:space:]]*=' "$configToml"; then
      echo "inline credential key leaked into generated TOML" >&2
      exit 1
    fi
    test -f "$rejectedConfigToml"
    if grep -F "$secretLiteral" "$rejectedConfigToml"; then
      echo "rejected credential literal leaked into generated TOML" >&2
      exit 1
    fi
    if grep -E '(password|secret)[[:space:]]*=' "$rejectedConfigToml"; then
      echo "rejected inline credential key leaked into generated TOML" >&2
      exit 1
    fi
    touch "$out"
  ''
