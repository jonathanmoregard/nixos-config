---
status: proposed
category: drift
date: 2026-04-27
source: mint-drift-agent
---

## claude-sandbox-proxy.service enabled on live but not declared in home-manager

~/.config/systemd/user/default.target.wants/claude-sandbox-proxy.service is enabled on the live system. No corresponding systemd.user.services entry exists in any visible .nix file (the imports in jonathan-linux.nix — autodoro.nix, router-services.nix, etc. — do not cover it). The service would not be installed or started on a fresh rebuild.

```
Read the unit file to get ExecStart and other fields:

  cat ~/.config/systemd/user/claude-sandbox-proxy.service

Then declare in a suitable .nix (e.g. home/jonathan-linux.nix):

  systemd.user.services.claude-sandbox-proxy = {
    Unit.Description = "...";
    Service.ExecStart = "...";
    Install.WantedBy = [ "default.target" ];
  };
```
