{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  inherit (lib)
    hasPrefix
    mkIf
    mkMerge
    mkOption
    optional
    types
    ;

  cfg = config.homeServer;
  toml = pkgs.formats.toml { };

  zigbeeEnabled = cfg.zigbeeSerialPort != null;
  mqttNetworkEnabled = cfg.mqttNetworkPasswordFile != null;
  houseAutomationEnabled = cfg.houseSettings != null;
  matrixEnabled = cfg.matrixServerName != null && cfg.matrixSecretFile != null;
  tellstickConfigured =
    cfg.tellstickAddress != null
    && cfg.tellstickTokenFile != null
    && cfg.tellstickAdapterPackage != null;
  deployEnabled = cfg.ageHostPublicKey != null && cfg.deployKeyFile != null;

  isRuntimePath = value:
    value == null
    || (
      hasPrefix "/" value
      && value != builtins.storeDir
      && !hasPrefix "${builtins.storeDir}/" value
    );

  zigbeeDeviceUnit =
    if zigbeeEnabled then
      "${utils.escapeSystemdPath cfg.zigbeeSerialPort}.device"
    else
      null;

  # Zigbee2MQTT falls back to GENERATE when the network key override is empty
  # or unparsable, silently forming a new network. Validate strictly and refuse
  # to start instead.
  zigbee2mqttWithNetworkKey = pkgs.writeShellApplication {
    name = "zigbee2mqtt-with-network-key";
    text = ''
      key=$(< "$CREDENTIALS_DIRECTORY/network-key")
      byte='(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'
      if [[ ! "$key" =~ ^\[$byte(,$byte){15}\]$ ]]; then
        echo "zigbee2mqtt: refusing to start: network key must be a compact JSON array of 16 bytes" >&2
        exit 1
      fi
      export ZIGBEE2MQTT_CONFIG_ADVANCED_NETWORK_KEY="$key"
      exec ${lib.getExe' config.services.zigbee2mqtt.package "zigbee2mqtt"}
    '';
  };
in
{
  imports = [
    ./build-coordination.nix
    ./house-automation-service.nix
    ./nixos-auto-deploy.nix
    ./smarthome-auto-deploy.nix
  ];

  options.homeServer = {
    ageHostPublicKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ssh-ed25519 AAAA... root@home-server";
      description = ''
        SSH host public key recorded from the installed server. Null keeps
        host-specific agenix rekeying disabled until the real key exists.
      '';
    };

    zigbeeSerialPort = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/dev/serial/by-id/usb-...";
      description = ''
        Stable by-id path for the Zigbee coordinator. Zigbee2MQTT is disabled
        while this is null; record the real path only after hardware discovery.
      '';
    };

    zigbeeChannel = mkOption {
      type = types.ints.between 11 26;
      default = 11;
      description = ''
        Zigbee radio channel. Changing it after devices have paired requires
        re-pairing them, so choose it once against local Wi-Fi usage.
      '';
    };

    zigbeePanId = mkOption {
      type = types.nullOr (types.ints.between 1 65534);
      default = null;
      description = ''
        Fixed Zigbee PAN ID. Required with `zigbeeSerialPort`: Zigbee2MQTT
        defaults it to GENERATE and the NixOS unit rewrites configuration.yaml
        on every start, so an unpinned value would change on each restart.
      '';
    };

    zigbeeExtendedPanId = mkOption {
      type = types.nullOr (types.listOf types.ints.u8);
      default = null;
      example = [ 1 2 3 4 5 6 7 8 ];
      description = ''
        Fixed 8-byte Zigbee extended PAN ID. Required with `zigbeeSerialPort`
        for the same reason as `zigbeePanId`.
      '';
    };

    zigbeeNetworkKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/zigbee2mqtt-network-key";
      description = ''
        Absolute runtime path to the Zigbee network key as a compact JSON array
        of 16 bytes. Required with `zigbeeSerialPort`. The key reaches
        Zigbee2MQTT through a systemd credential, never the Nix store, and a
        missing or malformed key stops the service instead of letting it
        generate a new network.
      '';
    };

    zigbeeFrontendTailnet = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Bind the Zigbee2MQTT frontend on all IPv4 addresses and admit port
        8080 only on tailscale0. Otherwise the frontend remains loopback-only.
      '';
    };

    mqttNetworkUsername = mkOption {
      type = types.str;
      default = "home-server-tailnet";
      description = "Username for the optional authenticated Tailscale MQTT listener.";
    };

    mqttNetworkPasswordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/home-server-mqtt";
      description = ''
        Absolute runtime path containing the clear-text password for the
        optional Tailscale MQTT user. Supplying this enables the authenticated
        listener; the file must not be copied into the Nix store.
      '';
    };

    mqttNetworkAcl = mkOption {
      type = types.listOf types.str;
      default = [ "readwrite house/v1/#" ];
      description = ''
        Mosquitto ACL entries for the optional Tailscale user. Zigbee2MQTT's
        native topic tree is deliberately not exposed by the default ACL.
      '';
    };

    mqttNetworkPort = mkOption {
      type = types.port;
      default = 1884;
      description = "Port for the optional authenticated Tailscale MQTT listener.";
    };

    houseAutomationEnvironmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/house-automation-mqtt";
      description = ''
        Optional runtime EnvironmentFile for house-automation MQTT credentials.
        The default loopback listener is anonymous, so this is normally null.
      '';
    };

    houseSettings = mkOption {
      type = types.nullOr toml.type;
      default = null;
      description = ''
        Declarative house-automation topology. Null keeps the daemon disabled
        until real rooms, devices, controls, and curves are recorded. Never
        place credentials in this value because it is rendered into the
        world-readable Nix store.
      '';
    };

    tellstickAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://192.0.2.1";
      description = ''
        Operator-verified local TellStick base address, recorded only after
        inspecting the bridge's own /api index. This module intentionally does
        not invent or start a TellStick adapter protocol.
      '';
    };

    tellstickTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/tellstick-token";
      description = ''
        Runtime path for the locally authorized TellStick token. When all
        TellStick options are set, systemd exposes it to the adapter through a
        private credential file rather than copying it into the Nix store.
      '';
    };

    tellstickAdapterPackage = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        Package providing bin/tellstick-mqtt-bridge. Null leaves the adapter
        disabled until the ZNet Lite v2 local API has been verified. The
        process receives TELLSTICK_BASE_URL, TELLSTICK_TOKEN_FILE, MQTT_URL,
        and MQTT_NAMESPACE; automation semantics remain in house-automationd.
      '';
    };

    matrixServerName = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "matrix.example.invalid";
      description = ''
        Permanent Synapse server_name. Matrix remains disabled while this or
        matrixSecretFile is null. Changing this identity after use is unsafe.
      '';
    };

    matrixSecretFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/matrix-synapse-secrets.yaml";
      description = ''
        Absolute runtime path to the Synapse YAML secret fragment. Matrix is
        enabled only when this and a permanent server name are both supplied.
      '';
    };

    matrixTailnet = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Bind the private client-only Synapse listener on all IPv4 addresses and
        admit port 8008 only on tailscale0. Otherwise it stays loopback-only.
      '';
    };

    deployKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/home-server-deploy-key";
      description = ''
        Runtime path reserved for the existing pull-deploy module. This service
        composition does not enable deployment before host identity, checkout,
        and credential readiness are all established.
      '';
    };

    smarthomeDeployKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/smarthome-deploy-ssh-key";
      description = ''
        Runtime path to the repository-specific read-only smarthome deploy
        key. Supplying it enables direct application deployment independently
        of the house topology.
      '';
    };

    adminHashedPasswordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/jonathan-password-hash";
      description = ''
        Runtime path containing Jonathan's hashed password. Null deliberately
        leaves bootstrap to `passwd`; the path must not enter the Nix store.
      '';
    };

    cloudApiEnvironmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/cloud-api-environment";
      description = ''
        Reserved runtime EnvironmentFile slot for a future cloud API consumer.
        No cloud service or credential format is invented by this module.
      '';
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = cfg.zigbeeSerialPort == null || hasPrefix "/dev/serial/by-id/" cfg.zigbeeSerialPort;
          message = "homeServer.zigbeeSerialPort must use a stable /dev/serial/by-id/ path";
        }
        {
          assertion = !cfg.zigbeeFrontendTailnet || zigbeeEnabled;
          message = "homeServer.zigbeeFrontendTailnet requires homeServer.zigbeeSerialPort";
        }
        {
          assertion =
            !zigbeeEnabled
            || (cfg.zigbeePanId != null && cfg.zigbeeExtendedPanId != null && cfg.zigbeeNetworkKeyFile != null);
          message = "homeServer.zigbeeSerialPort requires zigbeePanId, zigbeeExtendedPanId, and zigbeeNetworkKeyFile so the Zigbee network survives restarts";
        }
        {
          assertion = cfg.zigbeeExtendedPanId == null || builtins.length cfg.zigbeeExtendedPanId == 8;
          message = "homeServer.zigbeeExtendedPanId must contain exactly 8 bytes";
        }
        {
          assertion = isRuntimePath cfg.zigbeeNetworkKeyFile;
          message = "homeServer.zigbeeNetworkKeyFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion = isRuntimePath cfg.mqttNetworkPasswordFile;
          message = "homeServer.mqttNetworkPasswordFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion = !mqttNetworkEnabled || builtins.match "[^:\\r\\n]+" cfg.mqttNetworkUsername != null;
          message = "homeServer.mqttNetworkUsername must be a non-empty Mosquitto username without ':' or newlines";
        }
        {
          assertion = !mqttNetworkEnabled || cfg.mqttNetworkAcl != [ ];
          message = "homeServer.mqttNetworkAcl must not be empty when defining the optional network listener";
        }
        {
          assertion = isRuntimePath cfg.houseAutomationEnvironmentFile;
          message = "homeServer.houseAutomationEnvironmentFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion =
            (cfg.tellstickAddress == null && cfg.tellstickTokenFile == null && cfg.tellstickAdapterPackage == null)
            || tellstickConfigured;
          message = "homeServer TellStick address, token file, and adapter package must be supplied together";
        }
        {
          assertion = isRuntimePath cfg.tellstickTokenFile;
          message = "homeServer.tellstickTokenFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion = tellstickConfigured -> (hasPrefix "http://" cfg.tellstickAddress || hasPrefix "https://" cfg.tellstickAddress);
          message = "homeServer.tellstickAddress must be an explicit http:// or https:// local bridge URL";
        }
        {
          assertion = (cfg.matrixServerName == null) == (cfg.matrixSecretFile == null);
          message = "homeServer.matrixServerName and homeServer.matrixSecretFile must be supplied together";
        }
        {
          assertion = isRuntimePath cfg.matrixSecretFile;
          message = "homeServer.matrixSecretFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion = !cfg.matrixTailnet || matrixEnabled;
          message = "homeServer.matrixTailnet requires Matrix server name and secret file";
        }
        {
          assertion = isRuntimePath cfg.deployKeyFile;
          message = "homeServer.deployKeyFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion = isRuntimePath cfg.smarthomeDeployKeyFile;
          message = "homeServer.smarthomeDeployKeyFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion = isRuntimePath cfg.adminHashedPasswordFile;
          message = "homeServer.adminHashedPasswordFile must be an absolute runtime path outside the Nix store";
        }
        {
          assertion = isRuntimePath cfg.cloudApiEnvironmentFile;
          message = "homeServer.cloudApiEnvironmentFile must be an absolute runtime path outside the Nix store";
        }
      ];

      services.mosquitto = {
        enable = true;
        persistence = true;
        dataDir = "/var/lib/mosquitto";
        listeners = [
          {
            address = "127.0.0.1";
            port = 1883;
            omitPasswordAuth = true;
            acl = [
              "topic readwrite zigbee2mqtt/#"
              "topic readwrite house/v1/#"
            ];
            settings.allow_anonymous = true;
          }
        ] ++ optional mqttNetworkEnabled {
          address = "0.0.0.0";
          port = cfg.mqttNetworkPort;
          settings.allow_anonymous = false;
          users.${cfg.mqttNetworkUsername} = {
            passwordFile = cfg.mqttNetworkPasswordFile;
            acl = cfg.mqttNetworkAcl;
          };
        };
      };

      services.buildCoordination.enable = true;

      networking.firewall.interfaces.tailscale0.allowedTCPPorts =
        optional mqttNetworkEnabled cfg.mqttNetworkPort
        ++ optional (zigbeeEnabled && cfg.zigbeeFrontendTailnet) 8080
        ++ optional (matrixEnabled && cfg.matrixTailnet) 8008;
    }

    (mkIf zigbeeEnabled {
      services.zigbee2mqtt = {
        enable = true;
        dataDir = "/var/lib/zigbee2mqtt";
        settings = {
          homeassistant.enabled = false;
          permit_join = false;
          availability.enabled = true;
          serial = {
            port = cfg.zigbeeSerialPort;
            adapter = "ember";
          };
          mqtt = {
            server = "mqtt://127.0.0.1:1883";
            base_topic = "zigbee2mqtt";
          };
          frontend = {
            enabled = true;
            host = if cfg.zigbeeFrontendTailnet then "0.0.0.0" else "127.0.0.1";
            port = 8080;
          };
          # network_key is deliberately absent: it arrives via the
          # environment from a systemd credential (see ExecStart below).
          advanced = {
            channel = cfg.zigbeeChannel;
            pan_id = cfg.zigbeePanId;
            ext_pan_id = cfg.zigbeeExtendedPanId;
          };
        };
      };

      systemd.services.zigbee2mqtt = {
        requires = [
          "mosquitto.service"
          zigbeeDeviceUnit
        ];
        after = [
          "mosquitto.service"
          zigbeeDeviceUnit
        ];
        # Without this, invalid settings make Zigbee2MQTT park an interactive
        # failure page on 0.0.0.0:8080 and never exit, so systemd never
        # retries. Configuration is declarative; there is nothing to onboard.
        environment.Z2M_ONBOARD_NO_SERVER = "1";
        serviceConfig = {
          LoadCredential = "network-key:${cfg.zigbeeNetworkKeyFile}";
          ExecStart = lib.mkForce (lib.getExe zigbee2mqttWithNetworkKey);
        };
      };
    })

    (mkIf houseAutomationEnabled {
      services.houseAutomation = {
        enable = true;
        settings = cfg.houseSettings;
        environmentFile = cfg.houseAutomationEnvironmentFile;
      };

      systemd.services.house-automationd = {
        requires = [ "mosquitto.service" ];
        after = [ "mosquitto.service" ];
      };
    })

    (mkIf tellstickConfigured {
      systemd.services.tellstick-mqtt-bridge = {
        description = "Local TellStick ZNet Lite v2 to MQTT adapter";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        requires = [ "mosquitto.service" ];
        after = [
          "network-online.target"
          "mosquitto.service"
        ];
        environment = {
          TELLSTICK_BASE_URL = cfg.tellstickAddress;
          TELLSTICK_TOKEN_FILE = "%d/tellstick-token";
          MQTT_URL = "mqtt://127.0.0.1:1883";
          MQTT_NAMESPACE = "house/v1/tellstick";
        };
        serviceConfig = {
          ExecStart = "${cfg.tellstickAdapterPackage}/bin/tellstick-mqtt-bridge";
          Restart = "on-failure";
          RestartSec = "5s";
          LoadCredential = "tellstick-token:${cfg.tellstickTokenFile}";
          DynamicUser = true;
          StateDirectory = "tellstick-mqtt-bridge";
          StateDirectoryMode = "0700";
          UMask = "0077";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          CapabilityBoundingSet = "";
        };
      };
    })

    (mkIf (cfg.ageHostPublicKey != null) {
      age.rekey.hostPubkey = cfg.ageHostPublicKey;
    })

    (mkIf deployEnabled {
      services.nixos-auto-deploy = {
        enable = true;
        workingDir = "/etc/nixos";
        flakeAttr = "home-server";
        sshKeyFile = cfg.deployKeyFile;
        notifyUser = null;
        webhook.enable = false;
      };

      systemd.services.nixos-deploy.unitConfig.ConditionPathIsDirectory =
        "/etc/nixos/.git";
    })

    (mkIf (cfg.smarthomeDeployKeyFile != null) {
      services.smarthome-auto-deploy = {
        enable = true;
        deployKeyFile = cfg.smarthomeDeployKeyFile;
        serviceName = if houseAutomationEnabled then "house-automationd.service" else null;
        healthUrl = if houseAutomationEnabled then "http://127.0.0.1:9876/healthz" else null;
      };
    })

    (mkIf matrixEnabled {
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_17;
        enableTCPIP = false;
        initdbArgs = [
          "--locale=C"
          "--encoding=UTF8"
        ];
        authentication = lib.mkForce ''
          local all all peer
        '';
        settings.listen_addresses = lib.mkForce "";
        ensureDatabases = [ "matrix-synapse" ];
        ensureUsers = [
          {
            name = "matrix-synapse";
            ensureDBOwnership = true;
          }
        ];
      };

      services.matrix-synapse = {
        enable = true;
        dataDir = "/var/lib/matrix-synapse";
        extraConfigFiles = [ cfg.matrixSecretFile ];
        log.root.level = "WARNING";
        settings = {
          server_name = cfg.matrixServerName;
          enable_registration = false;
          report_stats = false;
          federation_domain_whitelist = [ ];
          trusted_key_servers = [ ];
          url_preview_enabled = false;
          max_upload_size = "50M";
          media_store_path = "/var/lib/matrix-synapse/media_store";
          database = {
            name = "psycopg2";
            args = {
              database = "matrix-synapse";
              user = "matrix-synapse";
              host = "/run/postgresql";
              cp_min = 5;
              cp_max = 10;
            };
          };
          listeners = [
            {
              port = 8008;
              bind_addresses = [
                (if cfg.matrixTailnet then "0.0.0.0" else "127.0.0.1")
              ];
              type = "http";
              tls = false;
              x_forwarded = false;
              resources = [
                {
                  names = [ "client" ];
                  compress = true;
                }
              ];
            }
          ];
        };
      };
    })

    (mkIf (cfg.adminHashedPasswordFile != null) {
      users.users.jonathan.hashedPasswordFile = cfg.adminHashedPasswordFile;
    })
  ];
}
