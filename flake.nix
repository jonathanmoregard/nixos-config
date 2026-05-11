{
  description = "jonathanmoregard's NixOS config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, agenix, ... }:
  let
    linuxSystem = "x86_64-linux";

    # Pre-built pkgs — overlays + allowUnfree applied here rather than in
    # modules. Required so tests/dellan-vm.nix can reuse the same pkgs:
    # the nixosTest framework injects pkgs externally and that makes
    # `nixpkgs.config` / `nixpkgs.overlays` read-only inside modules.
    pkgsLinux = import nixpkgs {
      system = linuxSystem;
      config.allowUnfree = true;
      overlays = [ (import ./overlays/beeper.nix) ];
    };
  in {
    # NixOS VM (headless, QEMU/KVM)
    nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
      system = linuxSystem;
      pkgs = pkgsLinux;
      modules = [
        ./hosts/vm/default.nix
        ./modules/common.nix
        ./modules/nixos/vm-tweaks.nix
        agenix.nixosModules.default
        { environment.systemPackages = [ agenix.packages.${linuxSystem}.default ]; }
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.jonathan = import ./home/jonathan-linux.nix;
        }
      ];
    };

    # Dell Latitude 7440 laptop — daily driver
    nixosConfigurations.dellan = nixpkgs.lib.nixosSystem {
      system = linuxSystem;
      pkgs = pkgsLinux;
      modules = [
        ./hosts/dellan/default.nix
        ./modules/common.nix
        agenix.nixosModules.default
        { environment.systemPackages = [ agenix.packages.${linuxSystem}.default ]; }
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.jonathan = import ./home/jonathan-linux.nix;
        }
      ];
    };

    # VM-based e2e tests. Run: `nix build .#checks.x86_64-linux.dellan-vm -L`
    checks.${linuxSystem}.dellan-vm = import ./tests/dellan-vm.nix {
      pkgs = pkgsLinux;
      inputs = { inherit home-manager agenix; };
    };

    # `nix run .#feature-vm` — boot dellan's config in an ephemeral
    # QEMU VM with sane defaults:
    #   * -snapshot   → all disk writes go to RAM, clean state every boot
    #   * -display none → headless; sshd reachable on host:2222
    #   * fresh $TMPDIR per launch, cleaned on exit → no leaks
    #   * stages host's ~/.ssh/id_ed25519 into a single-file cache dir
    #     that gets 9p-exported into the VM as /mnt/host-ssh, so the VM
    #     only sees the one file agenix needs (no known_hosts, no
    #     other keys). See modules/nixos/feature-vm.nix.
    apps.${linuxSystem}.feature-vm = {
      type = "app";
      program =
        let
          vm = self.nixosConfigurations.dellan.config.system.build.vm;
          runner = pkgsLinux.writeShellApplication {
            name = "feature-vm";
            text = ''
              hostKey="$HOME/.ssh/id_ed25519"
              if [ ! -r "$hostKey" ]; then
                echo "[feature-vm] ERROR: host SSH private key not readable at $hostKey" >&2
                echo "[feature-vm] agenix decryption inside the VM would silently produce empty secrets — refusing to boot." >&2
                exit 1
              fi

              # Stage the privkey into a launcher-owned cache dir so
              # the 9p export sees only the one file it needs.
              # Matches the path baked into modules/nixos/feature-vm.nix.
              stagingDir="$HOME/.cache/feature-vm/host-ssh"
              mkdir -p "$stagingDir"
              chmod 0700 "$stagingDir"
              install -m 0400 "$hostKey" "$stagingDir/id_ed25519"

              TMPDIR="$(mktemp -d -t feature-vm.XXXXXX)"
              export TMPDIR
              trap 'rm -rf "$TMPDIR"' EXIT INT TERM

              export QEMU_OPTS="''${QEMU_OPTS:--snapshot -display none}"
              echo "[feature-vm] tmpdir=$TMPDIR  qemu_opts=$QEMU_OPTS" >&2
              echo "[feature-vm] ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/id_ed25519 jonathan@localhost" >&2
              # Don't `exec` — we need bash to stay alive long enough
              # to run the trap that cleans $TMPDIR on QEMU exit.
              cd "$TMPDIR"
              ${vm}/bin/run-dellan-vm "$@"
            '';
          };
        in
        "${runner}/bin/feature-vm";
    };
  };
}
