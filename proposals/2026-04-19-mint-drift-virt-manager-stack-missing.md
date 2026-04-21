---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## virt-manager / QEMU / libvirt stack not in config

virt-manager, qemu-system-x86, libvirt-clients, and libvirt-daemon-system are all in apt-mark showmanual. On NixOS virtualisation must be enabled at the system level and the user must be in the libvirtd group; there is no equivalent in the current config.

```
In modules/nixos/desktop.nix (or a dedicated vm.nix):
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;
  users.users.jonathan.extraGroups = [ "libvirtd" ];
```
