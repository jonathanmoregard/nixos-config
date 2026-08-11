{ pkgs, ... }:
# Desktop-grade libvirt/QEMU stack for running full-OS guests (Windows,
# other Linux distros) with a real GUI. Distinct from microvm.nix, which
# is for lightweight NixOS-only guests declared as flake modules — this
# module handles the stateful, imperative-VM case (qcow2 disks under
# /var/lib/libvirt/images/, ISO installs, per-VM virsh XML).
#
# What lands:
#   - libvirtd + qemu_kvm + swtpm (TPM 2.0 — Win11 install requirement)
#   - OVMFFull (UEFI firmware — required for Q35 + Secure Boot)
#   - virt-manager (GUI), virt-viewer (SPICE client), virt-install (CLI)
#   - jonathan added to `libvirtd` + `kvm` groups so no-sudo virsh works
#   - `win-vm` on PATH — subcommands: fetch-iso, create, view, start, stop
#
# The Win11 ISO is NOT baked into the closure. Microsoft's download page
# uses per-session JS-generated URLs that expire; the wrapper takes a
# fresh URL as an argument. See home/win-vm.nix.
{
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      # OVMF is auto-bundled by qemu in nixpkgs 25.11+; the
      # `qemu.ovmf` submodule was removed. TPM 2.0 (Win11 requirement)
      # is provided by swtpm — package added to systemPackages below.
      swtpm.enable = true;
    };
  };

  # SPICE agent + USB redirection — makes the guest desktop feel
  # responsive and lets USB devices pass through virt-viewer.
  virtualisation.spiceUSBRedirection.enable = true;

  # virt-manager (GUI) — this option also wires the polkit rules so
  # libvirtd-group members drive libvirt without sudo prompts.
  programs.virt-manager.enable = true;

  environment.systemPackages = [
    pkgs.virt-viewer
    pkgs.spice-gtk
    pkgs.swtpm
    (import ../../home/win-vm.nix { inherit pkgs; })
  ];

  users.users.jonathan.extraGroups = [ "libvirtd" "kvm" ];

  # Persistent VM disks + ISOs live here. 0770 root:libvirtd so
  # libvirtd's qemu can read/write and members of libvirtd (jonathan)
  # can drop ISOs in.
  systemd.tmpfiles.rules = [
    "d /var/lib/libvirt/images 0770 root libvirtd -"
  ];
}
