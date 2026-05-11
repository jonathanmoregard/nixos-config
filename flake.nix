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

    # `nix run .#update-beeper` — rewrites overlays/beeper.nix to the latest
    # upstream Beeper release. Wired into .github/workflows/update-beeper.yml.
    packages.${linuxSystem}.update-beeper = pkgsLinux.beeper-update;
  };
}
