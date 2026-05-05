---
status: proposed
category: drift
subcategory: systemd
date: 2026-05-05
source: mint-drift-agent
---

## Custom /etc/systemd/system/usb-c-power.service not in nixos-config

`usb-c-power.service` was placed under `/etc/systemd/system/` on Mint by hand. It writes `on` to `power/control` for any present USB-C ports at the `USBC000:00` ACPI device, disabling per-port autosuspend so peripherals stop dropping when the bus idles. No equivalent declaration exists in any nixos-config module — would be lost on a fresh dellan install.

Captured live unit content (Mint host, 2026-05-05):

```ini
[Unit]
Description=Disable USB-C port autosuspend
After=sys-subsystem-typec.device
Wants=sys-subsystem-typec.device

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -f /sys/devices/platform/USBC000:00/typec/port0/power/control ]; then echo on > /sys/devices/platform/USBC000:00/typec/port0/power/control; fi && if [ -f /sys/devices/platform/USBC000:00/typec/port1/power/control ]; then echo on > /sys/devices/platform/USBC000:00/typec/port1/power/control; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

### Fix — declarative port via systemd.services

Add to `modules/nixos/laptop.nix`:

```nix
systemd.services.usb-c-power = {
  description = "Disable USB-C port autosuspend";
  after = [ "sys-subsystem-typec.device" ];
  wants = [ "sys-subsystem-typec.device" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = pkgs.writeShellScript "usb-c-power-on" ''
      for port in /sys/devices/platform/USBC000:00/typec/port*/power/control; do
        [ -f "$port" ] && echo on > "$port"
      done
    '';
  };
};
```

### Verify
- Confirm `/sys/devices/platform/USBC000:00` exists on dellan (Dell Latitude 7440). If absent, the service is a no-op — harmless. If the path differs (e.g. `USBC0001:00`), update the glob.
- After rebuild: `systemctl status usb-c-power.service` → active (exited).
