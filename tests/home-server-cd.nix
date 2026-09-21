# vm-home-server-cd: real pull-deploy, activation, idempotency, and rollback.
#
# Run: nix build --no-link --rebuild .#checks.x86_64-linux.vm-home-server-cd -L
{
  pkgs,
  inputs,
  inputSources,
  homeServerCdSystem,
  homeServerCdV2System,
}:

let
  repositorySource = ../.;
in

pkgs.testers.runNixOSTest {
  name = "vm-home-server-cd";
  skipTypeCheck = true;

  nodes.home-server =
    { lib, ... }:
    {
      imports = [
        inputs.agenix.nixosModules.default
        inputs.agenix-rekey.nixosModules.default
        ../hosts/home-server/default.nix
        ../modules/common.nix
        ./fixtures/home-server-cd-module.nix
      ];

      # Keep source, every direct/transitive locked input, and the exact
      # candidate runtime closures registered in the guest store. This models
      # the existing workstation/CI build boundary while still executing real
      # evaluation, generation registration, and activation in the guest.
      system.extraDependencies = inputSources ++ [
        homeServerCdSystem
        homeServerCdV2System
        pkgs.stdenvNoCC
      ];
      environment.etc."home-server-cd-source".source = repositorySource;
      virtualisation = {
        cores = 4;
        memorySize = 8192;
        diskSize = 131072;
      };
    };

  testScript = ''
    start_all()
    home_server.wait_for_unit("multi-user.target")
    home_server.wait_for_unit("mosquitto.service")
    home_server.wait_for_unit("house-automationd.service")
    home_server.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9876/healthz", timeout=60
    )

    home_server.succeed("test $(nproc) -eq 4")
    memory_kib = int(home_server.succeed("awk '/MemTotal/ {print $2}' /proc/meminfo"))
    assert 7_500_000 <= memory_kib <= 8_500_000, memory_kib
    disk_bytes = int(home_server.succeed("blockdev --getsize64 /dev/vda"))
    assert disk_bytes == 128 * 1024**3, disk_bytes
    assert home_server.succeed("findmnt -n -o FSTYPE /").strip() == "ext4"
    assert home_server.succeed("cat /etc/cd-release").strip() == "v1"

    home_server.succeed(
        "install -d -m 0755 /etc/nixos "
        "&& cp -aL /etc/home-server-cd-source/. /etc/nixos/ "
        "&& chmod -R u+w /etc/nixos "
        "&& git -C /etc/nixos init -q -b main "
        "&& git -C /etc/nixos config user.email cd-vm@example.invalid "
        "&& git -C /etc/nixos config user.name cd-vm "
        "&& git -C /etc/nixos add -A "
        "&& git -C /etc/nixos commit -q -m v1"
    )
    v1_sha = home_server.succeed("git -C /etc/nixos rev-parse HEAD").strip()
    home_server.succeed(
        "git clone -q --bare /etc/nixos /var/lib/home-server-cd-origin.git "
        "&& git -C /etc/nixos remote add origin /var/lib/home-server-cd-origin.git"
    )

    # Seed generation 1 from the same fixture. NixOS test VMs boot a direct
    # toplevel and do not otherwise have a rollback generation in the profile.
    home_server.succeed(
        "cd /etc/nixos && nixos-rebuild switch --flake .#home-server-cd",
        timeout=3600,
    )
    baseline_generation = int(
        home_server.succeed(
            "nix-env --list-generations -p /nix/var/nix/profiles/system "
            "| awk '/\\(current\\)/ {print $1}'"
        )
    )
    baseline_system = home_server.succeed("readlink -f /run/current-system").strip()
    print(f"[diag] v1 sha={v1_sha} generation={baseline_generation} system={baseline_system}")

    home_server.succeed(
        "printf 'v2\\n' > /etc/nixos/tests/fixtures/home-server-cd-release "
        "&& git -C /etc/nixos add tests/fixtures/home-server-cd-release "
        "&& git -C /etc/nixos commit -q -m v2 "
        "&& git -C /etc/nixos push -q origin main"
    )
    v2_sha = home_server.succeed("git -C /etc/nixos rev-parse HEAD").strip()
    home_server.succeed(f"git -C /etc/nixos reset -q --hard {v1_sha}")

    home_server.succeed("systemctl start nixos-deploy.service", timeout=3600)
    deployed_generation = int(
        home_server.succeed(
            "nix-env --list-generations -p /nix/var/nix/profiles/system "
            "| awk '/\\(current\\)/ {print $1}'"
        )
    )
    deployed_system = home_server.succeed("readlink -f /run/current-system").strip()
    deployed_sha = home_server.succeed("git -C /etc/nixos rev-parse HEAD").strip()
    last_good = home_server.succeed("cat /var/lib/nixos-deploy/last-good").strip()
    marker = home_server.succeed("cat /etc/cd-release").strip()
    journal = home_server.succeed("journalctl -u nixos-deploy.service --no-pager")
    print(
        f"[diag] v2 sha={v2_sha} checkout={deployed_sha} last-good={last_good} "
        f"generation={deployed_generation} system={deployed_system} marker={marker}"
    )
    print(f"[diag] deploy journal:\n{journal}")
    assert deployed_sha == v2_sha, (deployed_sha, v2_sha)
    assert last_good == v2_sha, (last_good, v2_sha)
    assert deployed_generation > baseline_generation, (
        baseline_generation,
        deployed_generation,
    )
    assert deployed_system != baseline_system, (baseline_system, deployed_system)
    assert marker == "v2", marker
    home_server.succeed("test ! -s /var/lib/nixos-deploy/poison-latch")
    home_server.wait_for_unit("mosquitto.service")
    home_server.wait_for_unit("house-automationd.service")
    home_server.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9876/healthz", timeout=60
    )
    home_server.succeed("test -z \"$(systemctl --failed --no-legend)\"")

    home_server.succeed("systemctl start nixos-deploy.service", timeout=300)
    replay_generation = int(
        home_server.succeed(
            "nix-env --list-generations -p /nix/var/nix/profiles/system "
            "| awk '/\\(current\\)/ {print $1}'"
        )
    )
    assert replay_generation == deployed_generation, (
        deployed_generation,
        replay_generation,
    )
    home_server.succeed(
        f"journalctl -u nixos-deploy.service --no-pager | grep -F "
        f"'already at {v2_sha}; no-op'"
    )

    home_server.succeed("nixos-rebuild switch --rollback", timeout=1800)
    rolled_generation = int(
        home_server.succeed(
            "nix-env --list-generations -p /nix/var/nix/profiles/system "
            "| awk '/\\(current\\)/ {print $1}'"
        )
    )
    rolled_system = home_server.succeed("readlink -f /run/current-system").strip()
    rolled_marker = home_server.succeed("cat /etc/cd-release").strip()
    print(
        f"[diag] rollback generation={rolled_generation} system={rolled_system} "
        f"marker={rolled_marker}"
    )
    assert rolled_generation == baseline_generation, (
        baseline_generation,
        rolled_generation,
    )
    assert rolled_system == baseline_system, (baseline_system, rolled_system)
    assert rolled_marker == "v1", rolled_marker

    home_server.succeed("systemctl start nixos-deploy.service", timeout=300)
    assert home_server.succeed("cat /etc/cd-release").strip() == "v1"
    assert home_server.succeed("cat /var/lib/nixos-deploy/last-good").strip() == v2_sha
    assert int(
        home_server.succeed(
            "nix-env --list-generations -p /nix/var/nix/profiles/system "
            "| awk '/\\(current\\)/ {print $1}'"
        )
    ) == baseline_generation
    home_server.succeed(
        "journalctl -u nixos-deploy.service --no-pager "
        "| grep -F 'rollback in effect; refusing to clobber'"
    )
  '';
}
