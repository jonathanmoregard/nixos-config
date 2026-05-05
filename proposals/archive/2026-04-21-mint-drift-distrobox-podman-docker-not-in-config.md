---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## distrobox, podman, and docker not declared in config

distrobox, podman, docker.io, and docker-compose-v2 are all installed via apt on the live system. None appear in the NixOS config. On NixOS these require both system-level virtualisation options and packages; they cannot simply be added to home.packages.

```
Add to the NixOS system config (e.g. modules/nixos/desktop.nix):

virtualisation.podman = {
  enable = true;
  dockerCompat = true;
};
virtualisation.docker.enable = true;

Add to home/desktop-apps.nix:
home.packages = with pkgs; [
  distrobox
  docker-compose
];
```
