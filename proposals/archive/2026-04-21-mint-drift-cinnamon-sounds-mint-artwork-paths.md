---
status: proposed
category: drift
date: 2026-04-21
source: mint-drift-agent
---

## Enabled Cinnamon sounds reference /usr/share/mint-artwork/ paths absent on NixOS

login-enabled, logout-enabled, plug-enabled, switch-enabled, tile-enabled, and unplug-enabled are all true in org.cinnamon.sounds, each pointing to /usr/share/mint-artwork/sounds/. The mint-artwork package does not exist in nixpkgs, so those paths will not exist on NixOS. The sounds will silently fail. The cinnamon.nix dconf block only sets notification-enabled/notification-file and does not disable the others.

```
Extend the "org/cinnamon/sounds" block in home/cinnamon.nix:

"org/cinnamon/sounds" = {
  notification-enabled = true;
  notification-file = "/home/jonathan/.local/share/sounds/tink.oga";
  login-enabled = false;
  logout-enabled = false;
  plug-enabled = false;
  switch-enabled = false;
  tile-enabled = false;
  unplug-enabled = false;
};
```
