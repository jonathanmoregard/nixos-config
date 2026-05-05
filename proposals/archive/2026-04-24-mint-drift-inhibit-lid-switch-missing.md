---
status: proposed
category: drift
date: 2026-04-24
source: mint-drift-agent
---

## inhibit-lid-switch = true set on live but absent from cinnamon.nix power dconf block

org.cinnamon.settings-daemon.plugins.power inhibit-lid-switch is true on the live system. When true, the settings daemon inhibits the kernel lid-switch event so logind does not act on it independently — lid-close behavior is handled exclusively by the software actions configured in the daemon (lid-close-ac-action etc.). The default is false. Without this setting, logind and the settings daemon may both react to a lid close, causing double-suspend or conflicting actions.

```
# In home/cinnamon.nix, add to the existing "org/cinnamon/settings-daemon/plugins/power" dconf block:
"org/cinnamon/settings-daemon/plugins/power" = {
  # ... existing keys ...
  inhibit-lid-switch = true;
};
```
