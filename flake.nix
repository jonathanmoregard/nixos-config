{
  description = "jonathanmoregard's NixOS + nix-darwin config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix.inputs.darwin.follows = "nix-darwin";
  };

  outputs = { self, nixpkgs, home-manager, nix-darwin, agenix, ... }:
  let
    linuxSystem = "x86_64-linux";
    darwinSystem = "aarch64-darwin";

    # Pre-built pkgs — overlays + allowUnfree applied here rather than in
    # modules. Required so tests/dellan-vm.nix can reuse the same pkgs:
    # the nixosTest framework injects pkgs externally and that makes
    # `nixpkgs.config` / `nixpkgs.overlays` read-only inside modules.
    pkgsLinux = import nixpkgs {
      system = linuxSystem;
      config.allowUnfree = true;
      overlays = [ (import ./overlays/beeper.nix) ];
    };
    pkgsDarwin = import nixpkgs {
      system = darwinSystem;
      config.allowUnfree = true;
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

    # Mac Mini (nix-darwin, placeholder — flesh out on arrival)
    darwinConfigurations.mac-mini = nix-darwin.lib.darwinSystem {
      system = darwinSystem;
      pkgs = pkgsDarwin;
      modules = [
        ./hosts/mac-mini/default.nix
        ./modules/common.nix
        ./modules/darwin/inference.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.jonathan = import ./home/jonathan.nix;
        }
      ];
    };
  };
}
