{
  description = "jonathanmoregard's NixOS + nix-darwin config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, nix-darwin, ... }:
  let
    linuxSystem = "x86_64-linux";
    darwinSystem = "aarch64-darwin";
  in {
    # NixOS VM (headless, QEMU/KVM)
    nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
      system = linuxSystem;
      modules = [
        ./hosts/vm/default.nix
        ./modules/common.nix
        ./modules/nixos/vm-tweaks.nix
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.jonathan = import ./home/jonathan-linux.nix;
        }
      ];
    };

    # Mac Mini (nix-darwin, placeholder — flesh out on arrival)
    darwinConfigurations.mac-mini = nix-darwin.lib.darwinSystem {
      system = darwinSystem;
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
