---
status: proposed
category: feature
date: 2026-05-03
source: manual
host: dellan
---

## Switch dellan DE from Cinnamon to KDE Plasma 6 (Wayland)

### Why now
Two unfixable-on-Cinnamon-X11 issues converged:

1. **No kinetic touchpad scroll in any terminal.** Ghostty and kitty both
   delegate momentum to the compositor. On X11, GTK4 only emits kinetic
   for `GDK_SOURCE_TOUCHSCREEN`, not `GDK_SOURCE_TOUCHPAD`. Mint's
   apparent momentum was libinput-1.25 firmware-trail events being
   consumed line-by-line — not a real feature, gone in libinput 1.27+.
   Confirmed via gnome-text-editor (GTK4 kinetic works fine — proves
   GTK is willing; X11 path is the blocker).
2. **Velocity-aware scroll** (short = exact, whip = slide) requires a
   compositor that ships kinetic events. Wayland compositors do; X11
   doesn't. Verified against kitty 0.46 docs:
   `momentum_scroll only applies on platforms such as Wayland`.

### Why Plasma specifically
- **Grayscale preserved.** Plasma 6.5 (Oct 2025) shipped a system-wide
  grayscale color filter at System Settings → Accessibility → Color
  Blindness Correction, with intensity slider (matches the current
  desaturate-all@hkoosha applet's 9% saturation setting).
- **Wayland session is stable** (unlike Cinnamon Wayland which is still
  experimental in Mint 22.2 / Cinnamon 6.x).
- Most apps unaffected — Qt, GTK, Electron all run on Plasma Wayland.
- KWin gestures + libinput give consistent touchpad behavior.

### Cost
Reimplement `home/cinnamon.nix` (~350 LOC dconf bundle) as KDE config:
- Panel layout, applets, themes (Mint-Y-Dark-Red → Breeze Dark variant)
- Touchpad gestures (org/cinnamon/gestures → KWin gestures)
- Night light keys (cinnamon settings-daemon → kwinrc NightColor)
- Default applications, MIME (xdg.mimeApps stays — not DE-specific)
- Autostart entries (.desktop files at same path — DE-agnostic)
- xbindkeys → kglobalshortcutsrc
- Nemo file manager → Dolphin (or keep nemo as alt)
- Grayscale applet → KWin grayscale shortcut binding

### Plan
1. Add Plasma 6 alongside Cinnamon at LightDM (parallel session, ~5 lines).
2. Run Plasma Wayland for a week without removing Cinnamon.
3. Port dconf bundle → KDE config files.
4. Verify: terminals get kinetic, grayscale toggle works, all autostart
   entries fire, daily apps unchanged.
5. If green: drop Cinnamon imports from `hosts/dellan/default.nix`,
   keep `home/cinnamon.nix` in tree (vm host still uses it).
6. If red: rollback by removing Plasma imports.

```
# hosts/dellan/default.nix — parallel-session sketch
services.desktopManager.plasma6.enable = true;
services.displayManager.defaultSession = "cinnamon";  # cinnamon stays default until cutover
```

### Notes
- vm host stays on Cinnamon; module split keeps that working.
- nixos-config flake currently imports cinnamon via
  `modules/nixos/desktop.nix` (system) + `home/cinnamon.nix` (HM).
  Plasma will need a parallel `modules/nixos/desktop-plasma.nix` +
  `home/plasma.nix`.
