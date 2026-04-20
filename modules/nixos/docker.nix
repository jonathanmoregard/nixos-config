{ ... }:
# TODO(nixos-migration): replace Docker with Firecracker via microvm.nix.
# Not 1:1 — microvm.nix declares per-VM modules rather than ad-hoc containers,
# and image workflows (docker pull / compose) will need replacements.
# Security rationale: Firecracker runs each workload in a hardware-virtualised KVM
# guest with its own kernel, so a container escape cannot reach the host kernel the
# way it can with Docker's shared-kernel namespaces + cgroups isolation.
# See: https://github.com/astro/microvm.nix
{
  virtualisation.docker.enable = true;
  users.users.jonathan.extraGroups = [ "wheel" "networkmanager" "docker" ];
}
