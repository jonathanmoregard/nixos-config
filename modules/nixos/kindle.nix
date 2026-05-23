{ ... }:
# Kindle USB: stop gvfs/udisks from auto-claiming the libusb interface so
# calibre's libmtp can open the device. Without this, Cinnamon's gvfs
# spawns gvfsd-mtp on plug and wins the interface race against calibre,
# which then reports `libusb_claim_interface() ... device is busy`.
# Vendor 1949 = Amazon (covers all Kindle models).
{
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="1949", ENV{UDISKS_IGNORE}="1", ENV{ID_MTP_DEVICE}="0"
  '';
}
