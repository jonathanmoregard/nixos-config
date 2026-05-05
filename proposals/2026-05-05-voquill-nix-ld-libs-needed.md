---
status: proposed
category: drift
subcategory: nix-ld
date: 2026-05-05
source: advice-refine-loop
---

## Voquill (Mint-built debug binary) won't start on dellan — nix-ld lacks Tauri lib closure

`/home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill` was rsync'd from Mint 2026-05-05. It is a 580 MB Tauri debug binary linked against Mint's `/lib/x86_64-linux-gnu/`. `programs.nix-ld.enable = true` is set in `modules/nixos/laptop.nix` so `/lib64/ld-linux-x86-64.so.2` resolves, but the loader still needs every `lib*.so.*` the binary depends on to be reachable via `LD_LIBRARY_PATH` (which nix-ld populates from `programs.nix-ld.libraries`).

Currently `programs.nix-ld.libraries` is unset → nix-ld's default closure only covers basic glibc/stdenv. Voquill autostart fires on every login (via `home/cinnamon.nix`) and silently fails.

### Captured Voquill lib dependencies (Mint host, 2026-05-05)

```
$ ldd ~/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill | grep "=>" | awk '{print $1}' | sort -u
libX11.so.6
libXinerama.so.1
libXtst.so.6
libasound.so.2
libcairo-gobject.so.2
libcairo.so.2
libdbus-1.so.3
libffi.so.8
libfribidi.so.0
libgcc_s.so.1
libgdk-3.so.0
libgdk_pixbuf-2.0.so.0
libgio-2.0.so.0
libglib-2.0.so.0
libgobject-2.0.so.0
libgtk-3.so.0
libjavascriptcoregtk-4.1.so.0
libpango-1.0.so.0
libpulse-simple.so.0
libpulse.so.0
libsoup-3.0.so.0
libwayland-client.so.0
libwebkit2gtk-4.1.so.0
libxdo.so.3
libxkbcommon.so.0
# plus standard glibc bits (libc, libm, libgcc_s)
```

### Fix

Edit `modules/nixos/laptop.nix`:

```nix
programs.nix-ld = {
  enable = true;
  libraries = with pkgs; [
    # GTK / Tauri / WebKit stack — for Voquill (and any future Tauri app)
    gtk3
    glib
    cairo
    pango
    gdk-pixbuf
    gobject-introspection
    libsoup_3
    webkitgtk_4_1
    libxkbcommon
    fribidi
    libffi
    # X11
    xorg.libX11
    xorg.libXtst
    xorg.libXinerama
    xorg.libXrandr
    xorg.libXcursor
    xorg.libXi
    xorg.libXext
    xorg.libXrender
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXfixes
    wayland
    # Audio
    libpulseaudio
    alsa-lib
    # Input automation (Voquill uses xdotool to inject keystrokes)
    xdotool
    # System
    dbus
    stdenv.cc.cc.lib
    zlib
    openssl
  ];
};
```

### Verify on dellan

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
# Confirm the binary now resolves all libs:
ldd /home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill | grep "not found"   # should be empty
# Try launching:
DISPLAY=:0 /home/jonathan/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill --voquill-autostart-hidden &
# Or via the autostart .desktop entry by logging out + back in.
```

### Follow-up
Once verified, see proposal `2026-05-05-voquill-build-from-source-on-dellan.md` for the durable fix (build Voquill on dellan, drop the Mint-built binary).
