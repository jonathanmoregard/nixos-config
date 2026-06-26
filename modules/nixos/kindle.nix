{ pkgs, ... }:
# Kindle USB: stop gvfs (via gvfs-mtp-volume-monitor + gvfsd-mtp) and
# udisks from auto-claiming the libusb interface so calibre's libmtp can
# open the device. Without this, Cinnamon's gvfs spawns gvfsd-mtp on plug
# and wins the interface race against calibre, which then reports
# `libusb_claim_interface() ... device is busy`.
#
# History (three failed attempts before this one):
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
# Attempt #3 (PR #108) — also unset `ID_MTP_DEVICE` AND `ID_MEDIA_PLAYER`
# in 60-kindle.rules. 50-udev-default.rules (file order 50) imports hwdb
# BEFORE 60-kindle.rules, so the unset wins by the time 69-libmtp.rules
# (file order 69) evaluates its early-exit branch. With no ID_MTP_DEVICE,
# no symlink, gvfs-mtp-volume-monitor has nothing to bind to.
#
# But that also broke calibre, because `/lib/udev/rules.d/70-uaccess.rules`
# line 70 hands the device's `uaccess` tag (which becomes a user ACL on
# the /dev/bus/usb/N/M device node) ONLY when `ID_MEDIA_PLAYER` is set:
#     SUBSYSTEM=="usb", ENV{ID_MEDIA_PLAYER}=="?*", TAG+="uaccess"
# Clearing ID_MEDIA_PLAYER on the kindle stripped that path. The device
# node ended up `crw-rw-r-- root:root` with no jonathan ACL, calibre got
# permission-denied opening it.
#
# Attempt #4 (this file) — only unset `ID_MTP_DEVICE`. Leave
# `ID_MEDIA_PLAYER` alone so 70-uaccess.rules:70 still grants the user
# ACL. 69-libmtp.rules:10's early-exit symlink branch only keys on
# `ID_MTP_DEVICE`, so clearing that alone is sufficient to suppress the
# /dev/libmtp-* symlink and stop gvfs-mtp-volume-monitor from spawning
# gvfsd-mtp. `MTP_NO_PROBE=1` is still required: clearing ID_MTP_DEVICE
# makes 69-libmtp.rules' fallback probe block eligible to re-tag the
# device (it runs `mtp-probe` which would respond positively and reset
# `ID_MTP_DEVICE=1`, re-creating the symlink). `UDISKS_IGNORE=1` keeps
# udisks2 from auto-mounting any partitions it would still detect.
#
# Scope: vendor 1949 = Amazon, product 9981 = Kindle Paperwhite (the
# device this user owns). Narrow to product because Kindle Fire tablets
# share the Amazon vendor ID and legitimately need MTP for file transfer
# — a vendor-wide rule would break them. If a future Kindle generation
# enumerates as a different PID, broaden this match.
#
# `ACTION!="remove"` keeps the rule from re-evaluating on unplug; the
# unset-and-flag work is only meaningful on `add` / `bind`. Per udev(7),
# all assignments on a single rule line are gated by the preceding
# match keys — if ACTION/SUBSYSTEM/ATTR don't match, none of the ENV
# assignments fire.
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
        ACTION!="remove", SUBSYSTEM=="usb", ATTR{idVendor}=="1949", ATTR{idProduct}=="9981", ENV{MTP_NO_PROBE}="1", ENV{UDISKS_IGNORE}="1", ENV{ID_MTP_DEVICE}=""
      '';
    })
  ];
}
