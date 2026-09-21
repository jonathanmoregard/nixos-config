# vm-home-server: headless Wyse host and private service-stack contract.
#
# Run: nix build --no-link .#checks.x86_64-linux.vm-home-server -L
{ pkgs, inputs }:

let
  mkFakeAutomation = fixture: pkgs.writeShellApplication {
    name = "house-automationd";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --config|--state) shift 2 ;;
          *) echo "unexpected argument: $1" >&2; exit 64 ;;
        esac
      done

      exec python3 -u - <<'PY'
      from http.server import BaseHTTPRequestHandler, HTTPServer

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path != "/healthz":
                  self.send_error(404)
                  return
              body = b'{"ready":true,"fixture":"${fixture}"}\n'
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, format, *args):
              pass

      HTTPServer(("127.0.0.1", 9876), Handler).serve_forever()
      PY
    '';
  };
  fakeAutomation = mkFakeAutomation "home-server";
  candidateAutomation = mkFakeAutomation "direct-deploy-v2";
  brokenAutomation = pkgs.writeShellScriptBin "house-automationd" ''
    exit 1
  '';
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    set -euo pipefail
    printf 'nix' >> "$STATE_DIRECTORY/nix-invocations"
    printf ' %q' "$@" >> "$STATE_DIRECTORY/nix-invocations"
    printf '\n' >> "$STATE_DIRECTORY/nix-invocations"
    [ "$#" -eq 12 ]
    [ "$1" = eval ]
    [ "$2" = --raw ]
    [ "$3" = --option ] && [ "$4" = max-jobs ] && [ "$5" = 0 ]
    [ "$6" = --option ] && [ "$7" = fallback ] && [ "$8" = false ]
    [ "$9" = --option ] && [ "''${10}" = builders ] && [ -z "''${11}" ]
    reference=''${12}
    source=''${reference%%#*}
    attribute=''${reference#*#}
    [ "$attribute" = packages.x86_64-linux.default.outPath ]
    cat "$source/release-path"
  '';
  fakeHydrator = pkgs.writeShellScriptBin "smarthome-hydrate-release-paths" ''
    set -euo pipefail
    [ "$#" -eq 9 ]
    [ "$1" = --from ]
    [ "$3" = --trusted-key ]
    [ "$5" = --timeout-seconds ] && [ "$6" = 300 ]
    [ "$7" = --interval ] && [ "$8" = 5 ]
    case "$9" in
      ${candidateAutomation}|${brokenAutomation}) ;;
      *) exit 1 ;;
    esac
    test -x "$9/bin/house-automationd"
    printf '%s\n' "$9" > "$STATE_DIRECTORY/hydrated-path"
  '';
  productionHardware = import ../hosts/home-server/hardware-configuration.nix {
    config = { };
    lib = pkgs.lib;
    modulesPath = "${pkgs.path}/nixos/modules";
  };
  productionRoot = productionHardware.fileSystems."/";
  deployWithoutTopology = inputs.nixpkgs.lib.nixosSystem {
    inherit pkgs;
    modules = [
      inputs.agenix.nixosModules.default
      inputs.agenix-rekey.nixosModules.default
      ../modules/nixos/home-server-services.nix
      {
        documentation.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        homeServer.smarthomeDeployKeyFile = "/run/smarthome-test-key";
        system.stateVersion = "25.11";
      }
    ];
  };
in

assert !deployWithoutTopology.config.services.houseAutomation.enable;
assert deployWithoutTopology.config.services.smarthome-auto-deploy.enable;
assert deployWithoutTopology.config.services.smarthome-auto-deploy.serviceName == null;
assert deployWithoutTopology.config.services.smarthome-auto-deploy.healthUrl == null;
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
        ../hosts/home-server/default.nix
        ../modules/common.nix
      ];

      disabledModules = [
        ../hosts/home-server/hardware-configuration.nix
      ];
      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

      homeServer = {
        smarthomeDeployKeyFile = lib.mkForce "/run/agenix/smarthome-deploy-key";
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
          install -m 0400 /dev/null /run/agenix/smarthome-deploy-key
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
        requires = [
          "fake-zigbee2mqtt-bridge.service"
          "home-server-test-smarthome-profile.service"
        ];
        after = [
          "fake-zigbee2mqtt-bridge.service"
          "home-server-test-smarthome-profile.service"
        ];
      };

      systemd.services.home-server-test-smarthome-profile = {
        description = "Install the VM fixture into the stable smarthome profile";
        before = [ "house-automationd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${config.nix.package}/bin/nix-env \
            --profile /nix/var/nix/profiles/smarthome \
            --set ${fakeAutomation}
        '';
      };

      services.smarthome-auto-deploy = {
        repoUrl = "file:///var/lib/smarthome-smoke-origin.git";
        nixPackage = fakeNix;
        hydratorPackage = fakeHydrator;
      };
      systemd.timers.smarthome-deploy.wantedBy = lib.mkForce [ ];

      environment.systemPackages = with pkgs; [
        curl
        git
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
        sshAuthorizedKeys = config.users.users.jonathan.openssh.authorizedKeys.keys;
        globalTcpPorts = config.networking.firewall.allowedTCPPorts;
        tailnetTcpPorts = config.networking.firewall.interfaces.tailscale0.allowedTCPPorts;
        journalConfig = config.services.journald.extraConfig;
        nixMinFree = config.nix.settings.min-free;
        nixMaxFree = config.nix.settings.max-free;
        nixKeepDerivations = config.nix.settings.keep-derivations;
        nixKeepOutputs = config.nix.settings.keep-outputs;
        nixGcAutomatic = config.nix.gc.automatic;
        nixGcDates = config.nix.gc.dates;
        nixGcOptions = config.nix.gc.options;
        nixOptimiseAutomatic = config.nix.optimise.automatic;
        nixOptimiseDates = config.nix.optimise.dates;
        smartdEnabled = config.services.smartd.enable;
        ageHostPublicKey = config.homeServer.ageHostPublicKey;
        deploySecretDeclared = config.age.secrets ? "deploy-ssh-key";
        deployKeyFile = config.homeServer.deployKeyFile;
        autoDeployEnabled = config.services.nixos-auto-deploy.enable;
        smarthomeDeployEnabled = config.services.smarthome-auto-deploy.enable;
        smarthomeProfile = config.services.smarthome-auto-deploy.profile;
        automationEnabled = config.services.houseAutomation.enable;
        automationExecutable = config.services.houseAutomation.executable;
        automationCondition =
          config.systemd.services.house-automationd.unitConfig.ConditionFileIsExecutable;
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
    assert (
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan"
        in values["sshAuthorizedKeys"]
    ), values
    assert values["globalTcpPorts"] == [], values
    assert values["tailnetTcpPorts"] == [22, 8008], values
    assert "Storage=persistent" in values["journalConfig"], values
    assert values["nixMinFree"] < values["nixMaxFree"], values
    assert values["nixKeepDerivations"] is False, values
    assert values["nixKeepOutputs"] is False, values
    assert values["nixGcAutomatic"] is True, values
    assert values["nixGcDates"] == ["daily"], values
    assert values["nixGcOptions"] == "--delete-older-than 14d", values
    assert values["nixOptimiseAutomatic"] is True, values
    assert values["smartdEnabled"] is True, values
    assert values["nixOptimiseDates"] == ["Wed 04:15"], values
    assert values["ageHostPublicKey"] == (
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEnGlRJufT9hIgzqFqHujW28DsSX1YDYg/0vGG7BsO1+ "
        "root@home-server"
    ), values
    assert values["deploySecretDeclared"] is True, values
    assert values["deployKeyFile"] == "/run/agenix/deploy-ssh-key", values
    assert values["autoDeployEnabled"] is True, values
    assert values["smarthomeDeployEnabled"] is True, values
    assert values["smarthomeProfile"] == "/nix/var/nix/profiles/smarthome", values
    assert values["automationEnabled"] is True, values
    assert values["automationExecutable"] == (
        "/nix/var/nix/profiles/smarthome/bin/house-automationd"
    ), values
    assert values["automationCondition"] == (
        "/nix/var/nix/profiles/smarthome/bin/house-automationd"
    ), values
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

    home_server.succeed("systemctl restart house-automationd.service")
    home_server.wait_until_succeeds(
      "curl --fail --silent http://127.0.0.1:9876/healthz | jq -e '.ready == true'"
    )

    baseline_generations = home_server.succeed(
        "nix-env --profile /nix/var/nix/profiles/smarthome "
        "--list-generations | awk '$1 ~ /^[0-9]+$/ { print $1 }'"
    ).strip().splitlines()
    assert len(baseline_generations) == 1, baseline_generations
    home_server.succeed(
        "git init -q /tmp/smarthome-work "
        "&& git -C /tmp/smarthome-work config user.email smoke@example.invalid "
        "&& git -C /tmp/smarthome-work config user.name smarthome-smoke "
        "&& printf '%s\\n' ${candidateAutomation} > /tmp/smarthome-work/release-path "
        "&& git -C /tmp/smarthome-work add release-path "
        "&& git -C /tmp/smarthome-work commit -qm v2 "
        "&& git -C /tmp/smarthome-work branch -M main "
        "&& git init -q --bare /var/lib/smarthome-smoke-origin.git "
        "&& git -C /tmp/smarthome-work remote add origin "
        "file:///var/lib/smarthome-smoke-origin.git "
        "&& git -C /tmp/smarthome-work push -q -u origin main"
    )
    revision = home_server.succeed(
        "git -C /tmp/smarthome-work rev-parse HEAD"
    ).strip()
    home_server.succeed(
        "test $(stat -c %a /run/agenix/smarthome-deploy-key) = 400"
    )
    home_server.succeed("systemctl start smarthome-deploy.service", timeout=300)
    home_server.succeed("test -s /var/lib/smarthome-deploy/last-success")
    home_server.wait_until_succeeds(
        "curl --fail --silent http://127.0.0.1:9876/healthz "
        "| jq -e '.fixture == \"direct-deploy-v2\"'",
        timeout=60,
    )
    marker = home_server.succeed(
        "cat /var/lib/smarthome-deploy/last-success"
    )
    print(f"[diag] direct deploy revision={revision} marker={marker!r}")
    assert f"rev={revision}\n" in marker, marker
    assert "path=${candidateAutomation}\n" in marker, marker
    home_server.succeed(
        "test $(readlink -f /nix/var/nix/profiles/smarthome) "
        "= ${candidateAutomation}"
    )
    home_server.succeed(
        "test $(cat /var/lib/smarthome-deploy/hydrated-path) "
        "= ${candidateAutomation}"
    )
    home_server.succeed(
        "grep -F -- '--option max-jobs 0 --option fallback false "
        "--option builders' /var/lib/smarthome-deploy/nix-invocations"
    )
    deployed_generations = home_server.succeed(
        "nix-env --profile /nix/var/nix/profiles/smarthome "
        "--list-generations | awk '$1 ~ /^[0-9]+$/ { print $1 }'"
    ).strip().splitlines()
    assert len(deployed_generations) == 2, deployed_generations

    home_server.succeed("systemctl start smarthome-deploy.service", timeout=300)
    replay_generations = home_server.succeed(
        "nix-env --profile /nix/var/nix/profiles/smarthome "
        "--list-generations | awk '$1 ~ /^[0-9]+$/ { print $1 }'"
    ).strip().splitlines()
    assert replay_generations == deployed_generations, (
        deployed_generations,
        replay_generations,
    )

    home_server.succeed(
        "printf '%s\\n' ${brokenAutomation} > /tmp/smarthome-work/release-path "
        "&& git -C /tmp/smarthome-work add release-path "
        "&& git -C /tmp/smarthome-work commit -qm broken-candidate "
        "&& git -C /tmp/smarthome-work push -q"
    )
    broken_revision = home_server.succeed(
        "git -C /tmp/smarthome-work rev-parse HEAD"
    ).strip()
    home_server.fail("systemctl start smarthome-deploy.service", timeout=300)
    rollback_marker = home_server.succeed(
        "cat /var/lib/smarthome-deploy/last-failure"
    )
    assert f"rev={broken_revision}\n" in rollback_marker, rollback_marker
    assert "path=${brokenAutomation}\n" in rollback_marker, rollback_marker
    assert "rollback=complete\n" in rollback_marker, rollback_marker
    assert home_server.succeed(
        "cat /var/lib/smarthome-deploy/last-success"
    ) == marker
    home_server.succeed(
        "test $(readlink -f /nix/var/nix/profiles/smarthome) "
        "= ${candidateAutomation}"
    )
    home_server.wait_until_succeeds(
        "curl --fail --silent http://127.0.0.1:9876/healthz "
        "| jq -e '.fixture == \"direct-deploy-v2\"'",
        timeout=60,
    )
    rollback_generations = home_server.succeed(
        "nix-env --profile /nix/var/nix/profiles/smarthome "
        "--list-generations | awk '$1 ~ /^[0-9]+$/ { print $1 }'"
    ).strip().splitlines()
    assert rollback_generations == deployed_generations, (
        deployed_generations,
        rollback_generations,
    )
    home_server.succeed("systemctl reset-failed smarthome-deploy.service")

    journal = home_server.succeed(
        "journalctl -u smarthome-deploy.service --no-pager"
    )
    print(f"[diag] direct deploy journal:\n{journal}")
    assert f"already deployed {revision} at ${candidateAutomation}" in journal, journal
    home_server.succeed("test -z \"$(systemctl --failed --no-legend)\"")
  '';
}
