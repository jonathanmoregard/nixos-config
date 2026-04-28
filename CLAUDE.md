# nixos-config

Jonathan's declarative system config — NixOS VM + Mac Mini, managed with Nix flakes + Home Manager.

## What this is

Mirroring a Linux Mint 22.2 / Cinnamon daily-driver setup into a reproducible NixOS VM (QEMU/KVM, 4 GB RAM). Goal: full repro — if the VM is wiped and rebuilt, it should come back exactly as left.

Mac Mini config is a placeholder (nix-darwin), fleshed out on arrival.

## Hosts

| Host | Target | Rebuild command |
|------|--------|-----------------|
| `vm` | NixOS x86_64 VM | `sudo nixos-rebuild switch --flake /etc/nixos#vm` |
| `dellan` | Dell Latitude 7440 (daily driver) | `sudo nixos-rebuild switch --flake /etc/nixos#dellan` |
| `mac-mini` | nix-darwin aarch64 | `darwin-rebuild switch --flake .#mac-mini` |

Alias on VM: `rebuild` (defined in `home/jonathan.nix`).

## VM e2e tests — DEFAULT before rebuilding `dellan`

Before `sudo nixos-rebuild switch --flake .#dellan`, run the ephemeral VM test:

```bash
nix build .#checks.x86_64-linux.dellan-vm -L
```

It boots a QEMU VM with the same modules as production (minus hardware-configuration), waits for `multi-user.target`, asserts HM activation, asserts user-level systemd timers/services, and runs sanity checks against HM-installed binaries. ~2-3 min; uses `/dev/kvm`.

Test source: `tests/dellan-vm.nix`. Add new assertions there when adding HM units, scripts, or systemd timers — keep this gate exercising real production paths.

**Why this is the gate, not `nixos-rebuild build-vm`:** `runNixOSTest` is sandboxed and returns a deterministic pass/fail derivation; `build-vm` is for interactive poking. Use `build-vm` only when debugging a failed test.

**Architecture note:** `nixpkgs.config.allowUnfree` and `nixpkgs.overlays` live in `flake.nix` (built into `pkgsLinux` / `pkgsDarwin` and passed to `nixosSystem`/`darwinSystem` via the `pkgs` argument). Setting them inside modules conflicts with `runNixOSTest`'s read-only nixpkgs injection. Keep new overlays in `flake.nix`'s `pkgsLinux` definition.

## Repo layout

`/home/jonathan/Repos/nixos-config` is a symlink to `/etc/nixos`. Same git repo — edits, status, and pulls in either path hit the same tree.

### Cross-repo bridge: `~/.claude/symlinks/`

AI infra (MCP servers, classifiers, helper binaries) lives in nixos-config — one `nixos-rebuild switch` deploys source + integration atomically. Hooks, slash commands, settings.json, agents stay in `~/.claude/` (Claude Code reads there).

`~/.claude/symlinks/` bridges the two. All `.claude` references to nixos-config code go through it, never absolute `/etc/nixos/...`. Built as a Nix-store derivation → read-only dir, contents = exactly what's declared:

```nix
# home/claude-symlinks.nix
home.file."claude/symlinks".source = pkgs.runCommand "claude-symlinks" {} ''
  mkdir -p $out && ln -s /etc/nixos/<path> $out/<name>
'';
```

Edits *through* symlinks write to nixos-config (intended). Adding a link = edit Nix + rebuild. `.claude/.gitignore` must include `/symlinks/`.

## Deploy workflow

Changes live on the host, rsync'd to VM — no GitHub credentials on VM:

```bash
rsync -avz --delete --exclude='.git' -e ssh --rsync-path="sudo rsync" \
  /home/jonathan/Repos/nixos-config/ jonathan@192.168.122.27:/etc/nixos/
```

VM IP may change on reboot — check with `virsh domifaddr nixos`.

## Key files

| File | Purpose |
|------|---------|
| `flake.nix` | Inputs + host definitions |
| `home/jonathan.nix` | Shared HM config (shell, git, packages, p10k) |
| `home/jonathan-linux.nix` | Linux HM entrypoint — imports, cloneRepos activation |
| `home/cinnamon.nix` | Cinnamon DE — applets, dconf, MIME defaults, autostart |
| `home/desktop-apps.nix` | GUI app packages (Chrome, Beeper, Discord, etc.) |
| `home/ghostty.nix` | Ghostty terminal config |
| `home/autodoro.nix` | Autodoro systemd user service |
| `modules/nixos/desktop.nix` | Cinnamon/LightDM system config + Chrome policies |
| `modules/nixos/vm-tweaks.nix` | VM-specific tweaks (QEMU guest, SPICE, etc.) |

## Cinnamon applet notes

- **desaturate-all@hkoosha** is fetched from GitHub via `pkgs.fetchgit` with `sparseCheckout`. Source pinned by rev + hash.
- Applet config files must be **real files**, not symlinks — Cinnamon can't read through nix store symlinks. Use `home.activation` (not `home.file`) for anything in `~/.config/cinnamon/spices/`.

## Secrets

gitleaks pre-commit hook blocks secrets. fetchgit hashes/revs that trigger false positives get `# pragma: allowlist secret` inline.

## Known gaps / manual steps

- **Dropbox**: daemon autostarts but `~/Dropbox` folder requires GUI login to Dropbox on first run.
- **Private repos**: `cloneRepos` activation tries SSH first (`git@github.com:...`), falls back to HTTPS. To clone private repos, add the host's SSH pubkey to https://github.com/settings/keys before next rebuild. Failures are silent — re-run `home-manager switch` after adding the key.
- **`~/.claude` repo**: NOT auto-cloned. Claude Code populates `~/.claude` with runtime state (backups, projects, sessions, cache) on first run, and the [.claude repo](https://github.com/jonathanmoregard/.claude.git) needs to coexist with that. Bootstrap: move runtime dirs aside, `git clone git@github.com:jonathanmoregard/.claude.git ~/.claude`, move dirs back in, then `cd ~/.claude && git submodule update --init --recursive`.
- **Beeper**: installed via nixpkgs (unfree, allowed). Requires account login on first run. nixpkgs version lags upstream — see `overlays/beeper.nix` for version bump.
- **`~/.huskyrc`**: declared in `home/jonathan.nix` (loads nvm for husky pre-commit hooks). NVM itself is not declared in this flake — install via `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash` if needed.
