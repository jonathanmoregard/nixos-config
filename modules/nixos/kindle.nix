{ pkgs, ... }:
# Kindle USB: stop gvfs (via gvfs-mtp-volume-monitor + gvfsd-mtp) and
# udisks from auto-claiming the libusb interface so calibre's libmtp can
# open the device. Without this, Cinnamon's gvfs spawns gvfsd-mtp on plug
# and wins the interface race against calibre, which then reports
# `libusb_claim_interface() ... device is busy`.
#
# The previous version dropped the rule via `services.udev.extraRules`,
# which lands in /etc/udev/rules.d/99-local.rules — i.e. AFTER nixpkgs's
# /etc/udev/rules.d/69-libmtp.rules. By the time our rule reset
# ID_MTP_DEVICE=0, the libmtp probe on line 34 had already (a) created
# the `/dev/libmtp-3-1` symlink and (b) set ID_MEDIA_PLAYER=1.
# gvfs-mtp-volume-monitor keys on the symlink and on ID_MEDIA_PLAYER,
# so the late reset was insufficient — gvfs still claimed the device
# every plug, and the cycle of disconnect/reconnect made calibre give up.
#
# Fix: ship the rule via `services.udev.packages` with destination
# `/lib/udev/rules.d/60-kindle.rules` (numerically before 69-libmtp) and
# pre-set `MTP_NO_PROBE=1` so the probe on line 34 of 69-libmtp.rules
# short-circuits before it can set ID_MTP_DEVICE / ID_MEDIA_PLAYER or
# create the symlink. `UDISKS_IGNORE=1` keeps udisks2 from auto-mounting
# the partitions it would still detect.
#
# Vendor 1949 = Amazon (covers all Kindle models).
#
# VM-untestable: requires a real Kindle on USB. Hardware-specific per the
# pipeline rule on lanes the VM can't model (touchpad / GPU / LUKS / real
# disks). Verified on dellan post-deploy by replugging the Kindle and
# checking that `pgrep -af gvfsd-mtp` stays empty and calibre detects
# the device on first plug. The deploy-time substitution of mtp-probe's
# /nix/store path into the existing 69-libmtp.rules doesn't affect this
# rule because we don't touch that file — we just pre-empt its probe.
{
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "60-kindle";
      destination = "/lib/udev/rules.d/60-kindle.rules";
      text = ''
        SUBSYSTEM=="usb", ATTR{idVendor}=="1949", ENV{MTP_NO_PROBE}="1", ENV{UDISKS_IGNORE}="1"
      '';
    })
  ];
}
