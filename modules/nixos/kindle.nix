{ pkgs, ... }:
# Kindle USB: stop gvfs (via gvfs-mtp-volume-monitor + gvfsd-mtp) and
# udisks from auto-claiming the libusb interface so calibre's libmtp can
# open the device. Without this, Cinnamon's gvfs spawns gvfsd-mtp on plug
# and wins the interface race against calibre, which then reports
# `libusb_claim_interface() ... device is busy`.
#
# History (two failed attempts before this one):
#
# Attempt #1 — `services.udev.extraRules` setting `ID_MTP_DEVICE=0`. Lands
# in /etc/udev/rules.d/99-local.rules — i.e. AFTER nixpkgs's
# /etc/udev/rules.d/69-libmtp.rules. By the time our rule reset
# ID_MTP_DEVICE, 69-libmtp's symlink branch had already created
# /dev/libmtp-3-N. gvfs-mtp-volume-monitor keys on the symlink, so the
# late reset was useless.
#
# Attempt #2 — pre-empt the libmtp probe at 60-kindle.rules with
# `MTP_NO_PROBE=1`. Didn't work because the probe was NEVER the path
# that tagged this device:
#   - 50-udev-default.rules:20 calls `IMPORT{builtin}="hwdb --subsystem=usb"`
#   - libmtp ships its own hwdb (lib/udev/hwdb.d/69-libmtp.hwdb) with
#     entries like `usb:v1949p9981* → ID_MTP_DEVICE=1, ID_MEDIA_PLAYER=1`
#   - so by the time 60-kindle.rules runs, ID_MTP_DEVICE is already set
#     by hwdb — and 69-libmtp.rules line 10 fires its early-exit branch
#     `ENV{ID_MTP_DEVICE}=="1", SYMLINK+="libmtp-%k", GOTO=end`, creating
#     the symlink before the probe (and our MTP_NO_PROBE guard on it)
#     can do anything.
#
# Attempt #3 (this file) — also unset `ID_MTP_DEVICE` and `ID_MEDIA_PLAYER`
# in 60-kindle.rules. 50-udev-default.rules (file order 50) imports hwdb
# BEFORE 60-kindle.rules, so the unset wins by the time 69-libmtp.rules
# (file order 69) evaluates its early-exit branch. With no ID_MTP_DEVICE,
# no symlink, gvfs-mtp-volume-monitor has nothing to bind to, and calibre
# wins the interface race. `MTP_NO_PROBE=1` is also still required: with
# `ID_MTP_DEVICE` cleared, 69-libmtp.rules' fallback probe block becomes
# eligible to re-tag the device (it runs `mtp-probe` which would respond
# positively and reset `ID_MTP_DEVICE=1`, re-creating the symlink).
# `UDISKS_IGNORE=1` keeps udisks2 from auto-mounting any partitions it
# would still detect.
#
# Scope: vendor 1949 = Amazon, product 9981 = Kindle Paperwhite (the
# device this user owns). Narrow to product because Kindle Fire tablets
# share the Amazon vendor ID and legitimately need MTP for file transfer
# — a vendor-wide rule would break them. If a future Kindle generation
# enumerates as a different PID, broaden this match.
#
# `ACTION!="remove"` keeps the rule from re-evaluating on unplug; the
# unset-and-flag work is only meaningful on `add` / `bind`.
#
# VM-untestable runtime behaviour: requires a real Kindle on USB.
# Hardware-specific per the pipeline rule on lanes the VM can't model
# (touchpad / GPU / LUKS / real disks). What the VM CAN verify is that
# the rule file is installed at the expected path with the expected
# contents — see `tests/base.nix`. Verified on dellan post-deploy by
# replugging the Kindle and checking that `pgrep -af gvfsd-mtp` stays
# empty, `/dev/libmtp-*` is absent, and calibre detects the device on
# first plug.
{
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "60-kindle";
      destination = "/lib/udev/rules.d/60-kindle.rules";
      text = ''
        ACTION!="remove", SUBSYSTEM=="usb", ATTR{idVendor}=="1949", ATTR{idProduct}=="9981", ENV{MTP_NO_PROBE}="1", ENV{UDISKS_IGNORE}="1", ENV{ID_MTP_DEVICE}="", ENV{ID_MEDIA_PLAYER}=""
      '';
    })
  ];
}
