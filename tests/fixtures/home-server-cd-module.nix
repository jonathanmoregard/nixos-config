{
  lib,
  modulesPath,
  pkgs,
  ...
}:

{
  imports = [
    (modulesPath + "/testing/test-instrumentation.nix")
    (modulesPath + "/virtualisation/qemu-vm.nix")
  ];

  # Candidate generations run on the NixOS test disk, not the future Wyse
  # installation. Keep its ext4 label contract and explicitly retain test
  # instrumentation so a real switch leaves the serial backdoor observable.
  disabledModules = [
    ../../hosts/home-server/hardware-configuration.nix
    ../../hosts/home-server/deployment-identity.nix
  ];
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  homeServer = {
    ageHostPublicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaYUR/n99axrFFFr/uv987jwaa6fYik7Ykf9iRSieZV root@nixos-vm";
    deployKeyFile = "/run/home-server-deploy-key";
    houseSettings = {
      schema_version = 1;
      mqtt = {
        host = "127.0.0.1";
        port = 1883;
        client_id = "home-server-cd-vm";
        application_namespace = "house/v1";
        zigbee2mqtt_base_topic = "zigbee2mqtt";
      };
      circadian = {
        daily_reset_time = "04:00";
        unfreeze_convergence_seconds = 30;
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
  };

  # Keep this synthetic target out of per-host local ciphertext storage. Its
  # fixture key is created below and no agenix secret is consumed at runtime.
  age.rekey.storageMode = lib.mkForce "derivation";

  # The production composition selects home-server. This fixture is an
  # extended generation in the same flake and changes only the deploy target.
  services.nixos-auto-deploy.flakeAttr = lib.mkForce "home-server-cd";
  # Prevent wall-clock boundaries from racing the deterministic scenario. The
  # real service stays intact and is invoked explicitly by the test.
  systemd.timers.nixos-deploy.wantedBy = lib.mkForce [ ];

  # QEMU has neither the future SSD SMART interface nor coordinator radio.
  # Keep production configuration enabled; suppress only runtime activation.
  systemd.services.smartd.wantedBy = lib.mkForce [ ];
  systemd.services.zigbee2mqtt.wantedBy = lib.mkForce [ ];

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

  systemd.tmpfiles.rules = [
    "f /run/home-server-deploy-key 0400 root root - test-fixture-only"
  ];

  environment.systemPackages = with pkgs; [
    curl
    git
    jq
  ];
  environment.etc."cd-release".text = builtins.readFile ./home-server-cd-release;

  system.extraDependencies = [ pkgs.stdenvNoCC ];
}
