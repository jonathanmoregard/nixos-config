---
status: proposed
category: feature
subcategory: build
date: 2026-05-05
source: advice-refine-loop
depends_on: 2026-05-05-voquill-nix-ld-libs-needed.md
---

## Replace rsync'd Mint-built Voquill binary with dellan-built one

Currently the Voquill executable at `~/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill` was rsync'd from Mint host on 2026-05-05 and is a 580 MB debug binary linked against Mint glibc + system libs. Even with the right nix-ld closure (sister proposal), this is a non-reproducible artifact: future `cargo build` runs can't reuse it (different host paths), `git clean -fdx` would delete it irrecoverably, and any Voquill code change requires the Mint-only-toolchain assumption to hold.

Source repo `~/Repos/voquill` is fully cloned on dellan. Rust + cargo are declared in `home/jonathan.nix` `home.packages`. node + pnpm too. So a dellan-native build is feasible — needs the system libs in scope at build time.

### Steps (run on dellan)

```bash
cd ~/Repos/voquill

# 1. Inspect Voquill's existing build instructions:
cat README.md | head -40
ls package.json apps/desktop/src-tauri/Cargo.toml

# 2. Frontend build (Tauri requires the SPA dist before backend build):
pnpm install
pnpm run build     # or `pnpm tauri build` per Tauri convention

# 3. Backend build (Rust). Tauri pulls system libs at compile time —
#    needs gtk3, webkit2gtk-4.1, libsoup-3.0 etc. as build inputs.
#    Easiest: enter a nix shell with those + cargo before building:
nix shell nixpkgs#gtk3 nixpkgs#webkitgtk_4_1 nixpkgs#libsoup_3 \
          nixpkgs#pkg-config nixpkgs#openssl nixpkgs#glib \
          nixpkgs#cairo nixpkgs#pango nixpkgs#gdk-pixbuf \
          nixpkgs#libxdo nixpkgs#dbus nixpkgs#wayland \
          nixpkgs#libsoup nixpkgs#javascriptcoregtk \
          --command bash -c "cd apps/desktop/src-tauri && cargo build"

# 4. The new binary appears at:
#    apps/desktop/src-tauri/target/debug/Voquill
#    Compare size + ldd vs the rsync'd one — the new build links
#    against /nix/store/.../lib paths only.

# 5. (Optional) `cargo build --release` for a smaller, faster binary.
#    Then update the autostart Exec= line in home/cinnamon.nix to
#    point at target/release/Voquill.

# 6. Smoke test:
DISPLAY=:0 ./apps/desktop/src-tauri/target/debug/Voquill --voquill-autostart-hidden &
```

### Durable fix (NixOS-native package)

The above is imperative — the binary lives outside the nix store, gets clobbered by `cargo clean`, and won't survive a fresh dellan install. For long-term reproducibility, package Voquill as a flake derivation (likely `pkgs.rustPlatform.buildRustPackage` for the Rust side + a wrapper that handles the pnpm frontend dist). That's a larger task — defer until daily-driver workflows have settled.

### Verify

```bash
# Once the dellan-built binary is in place:
ldd ~/Repos/voquill/apps/desktop/src-tauri/target/debug/Voquill | grep -c "/nix/store/"
# Expect: a count > 0 (most libs from /nix/store, not /lib/x86_64-linux-gnu)

# Autostart check at next login:
pgrep -af Voquill
```

### Notes
- Voquill's Tauri version + WebKit ABI on dellan must match what the source assumes (4.1). `pkgs.webkitgtk_4_1` is the right choice; `webkitgtk` (default 6.0) would break.
- If the build fails on `xdotool` linkage (Voquill uses xdo for keystroke injection), add `pkgs.xdotool` to the nix shell deps.
