# vm-home-server: headless Wyse host and private service-stack contract.
#
# Run: nix build --no-link .#checks.x86_64-linux.vm-home-server -L
{ pkgs, inputs }:

let
  productionHardware = import ../hosts/home-server/hardware-configuration.nix {
    config = { };
    lib = pkgs.lib;
    modulesPath = "${pkgs.path}/nixos/modules";
  };
  productionRoot = productionHardware.fileSystems."/";
in

pkgs.testers.runNixOSTest {
  name = "vm-home-server";
  skipTypeCheck = true;

  nodes.home-server =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.agenix.nixosModules.default
        inputs.agenix-rekey.nixosModules.default
        inputs.smarthome.nixosModules.default
        ../hosts/home-server/default.nix
        ../modules/common.nix
      ];

      disabledModules = [ ../hosts/home-server/hardware-configuration.nix ];
      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

      homeServer = {
        zigbeeSerialPort = "/dev/serial/by-id/usb-simulated-zbdongle-e";
        houseSettings = {
          schema_version = 1;
          mqtt = {
            host = "127.0.0.1";
            port = 1883;
            client_id = "home-server-vm";
            application_namespace = "house/v1";
            zigbee2mqtt_base_topic = "zigbee2mqtt";
          };
          circadian = {
            daily_reset_time = "04:00";
            unfreeze_convergence_seconds = 30;
          };
          acknowledgement = {
            overlay_id = "circadian-ack";
            amplitude = 0.10;
            duration_ms = 180;
            priority = 100;
          };
          health.bind = "127.0.0.1:9876";
          floors = [ { id = "test-floor"; } ];
          rooms = [
            {
              id = "test-room";
              floor = "test-floor";
            }
          ];
          curves = [
            {
              id = "test-day";
              anchors = [
                {
                  time = "04:00";
                  brightness = 0.10;
                  color_temperature_kelvin = 2200;
                }
                {
                  time = "16:00";
                  brightness = 0.80;
                  color_temperature_kelvin = 4000;
                }
              ];
            }
          ];
          scopes = [
            {
              id = "test-room-lights";
              kind = "room";
              room = "test-room";
              curve = "test-day";
            }
          ];
          devices = [
            {
              id = "test-lamp";
              friendly_name = "test/room/lamp";
              room = "test-room";
              capabilities.on_off = true;
            }
          ];
          controls = [
            {
              id = "test-control";
              friendly_name = "test/room/control";
              selected_scope = "test-room-lights";
              mappings = [
                {
                  gesture = "center_single";
                  target = "selected";
                  action.kind = "toggle_power";
                }
              ];
            }
          ];
        };
        tellstickAddress = "http://192.0.2.1";
        tellstickTokenFile = "/run/agenix/tellstick-token";
        tellstickAdapterPackage = pkgs.writeShellApplication {
          name = "tellstick-mqtt-bridge";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            test "$TELLSTICK_BASE_URL" = "http://192.0.2.1"
            test "$MQTT_URL" = "mqtt://127.0.0.1:1883"
            test "$MQTT_NAMESPACE" = "house/v1/tellstick"
            test "$(cat "$TELLSTICK_TOKEN_FILE")" = "vm-tellstick-token"
            touch "$STATE_DIRECTORY/ready"
            exec sleep infinity
          '';
        };
        matrixServerName = "matrix.example.invalid";
        matrixSecretFile = "/run/agenix/matrix-synapse-secrets.yaml";
        matrixTailnet = true;
      };

      # Static Zigbee2MQTT configuration is evaluated, but no fake character
      # device pretends to be coordinator hardware in this VM. Likewise, QEMU's
      # virtual disk has no SMART interface; keep production SMART enabled while
      # avoiding an expected failed unit in runtime smoke tests.
      systemd.services.zigbee2mqtt.wantedBy = lib.mkForce [ ];
      systemd.services.smartd.wantedBy = lib.mkForce [ ];

      systemd.services.home-server-test-secrets = {
        description = "Create runtime-only service fixture secrets";
        before = [
          "matrix-synapse.service"
          "tellstick-mqtt-bridge.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0755 /run/agenix
          install -o matrix-synapse -g matrix-synapse -m 0400 /dev/null \
            /run/agenix/matrix-synapse-secrets.yaml
          printf '%s\n' \
            'macaroon_secret_key: vm-macaroon-secret' \
            'form_secret: vm-form-secret' \
            'registration_shared_secret: vm-registration-secret' \
            > /run/agenix/matrix-synapse-secrets.yaml
          printf '%s\n' 'vm-tellstick-token' > /run/agenix/tellstick-token
          chmod 0400 /run/agenix/tellstick-token
        '';
      };
      systemd.services.matrix-synapse = {
        requires = [ "home-server-test-secrets.service" ];
        after = [ "home-server-test-secrets.service" ];
      };
      systemd.services.tellstick-mqtt-bridge = {
        requires = [ "home-server-test-secrets.service" ];
        after = [ "home-server-test-secrets.service" ];
      };

      systemd.services.fake-zigbee2mqtt-bridge = {
        description = "Publish retained simulated Zigbee2MQTT readiness";
        wantedBy = [ "multi-user.target" ];
        after = [ "mosquitto.service" ];
        requires = [ "mosquitto.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          until ${pkgs.mosquitto}/bin/mosquitto_pub \
            -h 127.0.0.1 -p 1883 -q 1 -r \
            -t zigbee2mqtt/bridge/state -m online
          do
            sleep 0.1
          done
        '';
      };
      systemd.services.house-automationd = {
        requires = [ "fake-zigbee2mqtt-bridge.service" ];
        after = [ "fake-zigbee2mqtt-bridge.service" ];
      };

      environment.systemPackages = with pkgs; [
        curl
        jq
        mosquitto
      ];

      environment.etc."home-server-contract.json".text = builtins.toJSON {
        hostName = config.networking.hostName;
        rootDevice = productionRoot.device;
        rootFsType = productionRoot.fsType;
        sshPasswordAuthentication = config.services.openssh.settings.PasswordAuthentication;
        sshKeyboardInteractiveAuthentication =
          config.services.openssh.settings.KbdInteractiveAuthentication;
        sshRootLogin = config.services.openssh.settings.PermitRootLogin;
        sshOpenFirewall = config.services.openssh.openFirewall;
        globalTcpPorts = config.networking.firewall.allowedTCPPorts;
        tailnetTcpPorts = config.networking.firewall.interfaces.tailscale0.allowedTCPPorts;
        journalConfig = config.services.journald.extraConfig;
        nixMinFree = config.nix.settings.min-free;
        nixMaxFree = config.nix.settings.max-free;
        nixGcAutomatic = config.nix.gc.automatic;
        nixGcDates = config.nix.gc.dates;
        nixGcOptions = config.nix.gc.options;
        nixOptimiseAutomatic = config.nix.optimise.automatic;
        nixOptimiseDates = config.nix.optimise.dates;
        smartdEnabled = config.services.smartd.enable;
        autoDeployEnabled = config.services.nixos-auto-deploy.enable;
        automationEnabled = config.services.houseAutomation.enable;
        tellstickEnabled = config.systemd.services.tellstick-mqtt-bridge.wantedBy;
        mqttLocalAcl = (builtins.head config.services.mosquitto.listeners).acl;
        zigbeeEnabled = config.services.zigbee2mqtt.enable;
        zigbeeSerialPort = config.services.zigbee2mqtt.settings.serial.port;
        zigbeeAdapter = config.services.zigbee2mqtt.settings.serial.adapter;
        zigbeeHomeAssistant = config.services.zigbee2mqtt.settings.homeassistant.enabled;
        zigbeePermitJoin = config.services.zigbee2mqtt.settings.permit_join;
        zigbeeAvailabilityEnabled = config.services.zigbee2mqtt.settings.availability.enabled;
        zigbeeFrontendHost = config.services.zigbee2mqtt.settings.frontend.host;
        matrixRegistration = config.services.matrix-synapse.settings.enable_registration;
        matrixServerName = config.services.matrix-synapse.settings.server_name;
        matrixDatabase = config.services.matrix-synapse.settings.database.name;
        matrixListener = builtins.head config.services.matrix-synapse.settings.listeners;
      };

      virtualisation = {
        memorySize = 3072;
        cores = 2;
        diskSize = 6144;
      };
    };

  testScript = ''
    home_server.wait_for_unit("multi-user.target")

    contract = home_server.succeed("cat /etc/home-server-contract.json")
    import json
    values = json.loads(contract)
    assert values["hostName"] == "home-server", values
    assert values["rootDevice"] == "/dev/disk/by-label/nixos", values
    assert values["rootFsType"] == "ext4", values
    assert values["sshPasswordAuthentication"] is False, values
    assert values["sshKeyboardInteractiveAuthentication"] is False, values
    assert values["sshRootLogin"] == "no", values
    assert values["sshOpenFirewall"] is False, values
    assert values["globalTcpPorts"] == [], values
    assert values["tailnetTcpPorts"] == [22, 8008], values
    assert "Storage=persistent" in values["journalConfig"], values
    assert values["nixMinFree"] < values["nixMaxFree"], values
    assert values["nixGcAutomatic"] is True, values
    assert values["nixGcDates"] == ["daily"], values
    assert values["nixGcOptions"] == "--delete-older-than 14d", values
    assert values["nixOptimiseAutomatic"] is True, values
    assert values["smartdEnabled"] is True, values
    assert values["nixOptimiseDates"] == ["Wed 04:15"], values
    assert values["autoDeployEnabled"] is False, values
    assert values["automationEnabled"] is True, values
    assert values["tellstickEnabled"] == ["multi-user.target"], values
    assert values["mqttLocalAcl"] == [
        "topic readwrite zigbee2mqtt/#",
        "topic readwrite house/v1/#",
    ], values
    assert values["zigbeeEnabled"] is True, values
    assert values["zigbeeSerialPort"] == "/dev/serial/by-id/usb-simulated-zbdongle-e", values
    assert values["zigbeeAdapter"] == "ember", values
    assert values["zigbeeHomeAssistant"] is False, values
    assert values["zigbeePermitJoin"] is False, values
    assert values["zigbeeAvailabilityEnabled"] is True, values
    assert values["zigbeeFrontendHost"] == "127.0.0.1", values
    assert values["matrixRegistration"] is False, values
    assert values["matrixServerName"] == "matrix.example.invalid", values
    assert values["matrixDatabase"] == "psycopg2", values
    assert values["matrixListener"]["bind_addresses"] == ["0.0.0.0"], values
    assert values["matrixListener"]["resources"] == [
        {"compress": True, "names": ["client"]}
    ], values

    home_server.wait_for_unit("tailscaled.service")
    home_server.wait_for_unit("mosquitto.service")
    home_server.wait_for_unit("house-automationd.service")
    home_server.wait_for_unit("tellstick-mqtt-bridge.service")
    home_server.wait_for_unit("postgresql.service")
    home_server.wait_for_unit("matrix-synapse.service")

    home_server.succeed(
        "curl --fail --silent http://127.0.0.1:8008/_matrix/client/versions | "
        "jq -e '.versions | length > 0'"
    )
    home_server.succeed(
        "runuser -u postgres -- psql -Atqc \"SELECT pg_get_userbyid(datdba) "
        "FROM pg_database WHERE datname='matrix-synapse'\" | grep -Fx matrix-synapse"
    )
    home_server.succeed("test -d /var/lib/matrix-synapse/media_store")
    home_server.succeed("test -d /var/lib/house-automation")
    home_server.succeed("test -d /var/lib/mosquitto")
    home_server.succeed("test -f /var/lib/private/tellstick-mqtt-bridge/ready")
    home_server.succeed("systemctl show zigbee2mqtt.service -P LoadState | grep -Fx loaded")
    home_server.succeed("systemctl show zigbee2mqtt.service -P ActiveState | grep -Fx inactive")
    home_server.succeed(
        "systemctl cat zigbee2mqtt.service | grep '^Requires=' | "
        "grep -F mosquitto.service | grep -F dev-serial-by | grep -F simulated"
    )

    home_server.succeed("systemctl show house-automationd.service -P Restart | grep -Fx on-failure")
    home_server.succeed("systemctl show house-automationd.service -P NoNewPrivileges | grep -Fx yes")
    home_server.succeed("systemctl show house-automationd.service -P ProtectSystem | grep -Fx strict")
    home_server.succeed("test -z \"$(systemctl show house-automationd.service -P CapabilityBoundingSet)\"")

    home_server.wait_until_succeeds(
        "curl --fail --silent http://127.0.0.1:9876/healthz | jq -e '.ready == true'"
    )
    home_server.succeed("ss -lnt | grep -F '127.0.0.1:1883'")
    home_server.fail("ss -lnt | grep -E '0[.]0[.]0[.]0:1883|[[]::[]]:1883'")
    home_server.succeed("ss -lnt | grep -F '0.0.0.0:8008'")
    home_server.fail("systemctl cat matrix-synapse.service | grep -F vm-macaroon-secret")
    home_server.fail("systemctl cat tellstick-mqtt-bridge.service | grep -F vm-tellstick-token")

    # Exercise the real broker/adapter path without a fake device echo. The
    # daemon must stop scheduling once its bounded retry budget is exhausted.
    home_server.succeed(
        """
        rm -f /tmp/startup-command.json
        (timeout 10 mosquitto_sub -h 127.0.0.1 -p 1883 -C 1 \
          -t zigbee2mqtt/test/room/lamp/set > /tmp/startup-command.json) &
        subscriber=$!
        sleep 0.2
        mosquitto_pub -h 127.0.0.1 -p 1883 -q 1 -r \
          -t zigbee2mqtt/test/room/lamp/availability -m online
        wait "$subscriber"
        jq -e '.state == "OFF"' /tmp/startup-command.json
        """
    )
    home_server.succeed(
        """
        rm -f /tmp/toggle-command.json
        (timeout 10 mosquitto_sub -h 127.0.0.1 -p 1883 -C 1 \
          -t zigbee2mqtt/test/room/lamp/set > /tmp/toggle-command.json) &
        subscriber=$!
        sleep 0.2
        mosquitto_pub -h 127.0.0.1 -p 1883 -q 1 \
          -t zigbee2mqtt/test/room/control -m '{"action":"toggle"}'
        wait "$subscriber"
        jq -e '.state == "ON"' /tmp/toggle-command.json
        """
    )
    home_server.succeed("sleep 16")
    before = int(home_server.succeed(
        "journalctl -u house-automationd.service --no-pager -o cat | "
        "grep -c 'computed device target' || true"
    ).strip())
    home_server.succeed("sleep 1")
    after = int(home_server.succeed(
        "journalctl -u house-automationd.service --no-pager -o cat | "
        "grep -c 'computed device target' || true"
    ).strip())
    assert after - before <= 1, (before, after)

    home_server.succeed("systemctl restart house-automationd.service")
    home_server.wait_until_succeeds(
        "curl --fail --silent http://127.0.0.1:9876/healthz | jq -e '.ready == true'"
    )
    home_server.succeed("test -z \"$(systemctl --failed --no-legend)\"")
  '';
}
