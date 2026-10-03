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
  # jonathan is deliberately NOT in the `docker` group: membership is
  # password-less root (mount / into a container), and jonathan is the uid
  # agents run as, so it would undo every root-only secret and the pr-swipe
  # uid split. Use `sudo docker …` for the rare interactive need.
  # (wheel / networkmanager come from profiles/base.nix.)
}
