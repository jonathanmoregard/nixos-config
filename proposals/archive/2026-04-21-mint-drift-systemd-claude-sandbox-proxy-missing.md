---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## claude-sandbox-proxy service not declared in home-manager

~/.config/systemd/user/claude-sandbox-proxy.service exists and is enabled (in default.target.wants/). No systemd.user.services declaration for it appears in any shown nix file. The proxy will not start on a fresh install.

```
Read the live unit file:
  cat ~/.config/systemd/user/claude-sandbox-proxy.service

Then add to a nix module:

systemd.user.services.claude-sandbox-proxy = {
  Unit.Description = "Claude sandbox proxy";
  Service.ExecStart = "<from live unit>";
  Install.WantedBy = [ "default.target" ];
};
```
