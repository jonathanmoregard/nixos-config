---
status: proposed
category: drift
subcategory: systemd
date: 2026-05-05
source: mint-drift-agent
---

## Custom /etc/systemd/system/usb-c-power.service not in nixos-config

usb-c-power.service appears in /etc/systemd/system/ alongside standard dbus-* alias units. Every other entry in that directory is a well-known distro service (bluez, avahi, thermald, etc.); usb-c-power is the only non-standard one and has no matching declaration in any nixos-config module. It would be absent on a fresh NixOS install.

```
# Inspect the unit first:
systemctl cat usb-c-power.service

# Then declare in modules/nixos/laptop.nix:
systemd.services.usb-c-power = {
  description = "USB-C power management";
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    # ... adapt from systemctl cat output
  };
};
```
