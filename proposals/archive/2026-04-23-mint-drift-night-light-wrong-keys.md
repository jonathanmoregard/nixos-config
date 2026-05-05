---
status: proposed
category: drift
date: 2026-04-23
source: mint-drift-agent
---

## Night-light schedule dconf keys in cinnamon.nix use non-existent schema keys

home/cinnamon.nix sets night-light-schedule-automatic = true, night-light-latitude = 59.2, and night-light-longitude = 18.03 under org/cinnamon/settings-daemon/plugins/color. None of these keys exist in the actual GSettings schema. The live system confirms the real key is night-light-schedule-mode = 'auto'. The coordinates are written at runtime by geoclue2 as night-light-last-coordinates and must not be configured manually. On a fresh NixOS build the unknown keys are silently ignored, leaving night-light-schedule-mode at its default value of 'manual' instead of 'auto', so the schedule will not follow sunrise/sunset.

```
# In home/cinnamon.nix, inside "org/cinnamon/settings-daemon/plugins/color", replace:
#   night-light-schedule-automatic = true;
#   night-light-latitude = 59.2;
#   night-light-longitude = 18.03;
# With:
night-light-schedule-mode = "auto";
# Remove the lat/lon lines entirely — geoclue2 populates night-light-last-coordinates at runtime.
```
