# nixos-config

Jonathan's declarative system config — NixOS VM + Mac Mini, managed with Nix flakes + Home Manager.

## What this is

Mirroring a Linux Mint 22.2 / Cinnamon daily-driver setup into a reproducible NixOS VM (QEMU/KVM, 4 GB RAM). Goal: full repro — if the VM is wiped and rebuilt, it should come back exactly as left.

Mac Mini config is a placeholder (nix-darwin), fleshed out on arrival.

## Hosts

| Host | Target |
|------|--------|
| `dellan` | Dell Latitude 7440 (daily driver) |
| `vm` | NixOS x86_64 VM (legacy; being phased out) |
| `mac-mini` | nix-darwin aarch64 (placeholder) |

**Manual `nixos-rebuild switch` is no longer the default workflow on dellan.** Auto-deploy on push to `main` handles it (see "Deploy workflow" below). Manual rebuilds are reserved for: bootstrap install, hardware-config edits the VM gate can't model, emergency rollback. Use `sudo nixos-rebuild switch --rollback` for emergency rollback.

## Dev workflow (worktree → branch → PR → auto-deploy)

**Repo layout:**

```
~/Repos/nixos-config/                    ← bare repo (no working tree)
~/Repos/nixos-config-worktrees/
    main/                                ← read-only browse worktree
    <branch-slug>/                       ← dev worktrees, one per branch
/etc/nixos/                              ← root-owned clone of origin/main
                                           (auto-pulled + rebuilt by
                                            nixos-deploy.service)
```

You CANNOT edit `~/Repos/nixos-config/` (no working tree). You CANNOT edit `/etc/nixos/` (root-owned, deploy target). Both fail by construction. **Always work in a worktree.**

**Standard flow for any change:**

```bash
# 1. Open a worktree
cd ~/Repos/nixos-config
git worktree add ~/Repos/nixos-config-worktrees/<slug> -b feat/<slug> main
cd ~/Repos/nixos-config-worktrees/<slug>

# 2. Edit, commit
$EDITOR home/whatever.nix
git add -A
git commit -m "feat(scope): summary"

# 3. Push branch + open PR
git push -u origin feat/<slug>
gh pr create --title "feat(scope): summary" --body "..."

# 4. Wait for CI (gate.yml + ci.yml run on the self-hosted runner on dellan)
gh pr checks <PR_NUMBER>

# 5. Read the PR comment from the classifier — assigns risk:trivial / low /
#    medium / high / critical based on derivation-graph blast radius
#    (see scripts/risk-rules.nix). risk:low/trivial auto-merge once green.
#    risk:medium/high/critical require human approval.

# 6. Merge (if not auto-merged). Auto-deploy webhook fires on push:main →
#    nixos-deploy.service runs `git fetch + reset --hard + nixos-rebuild
#    switch` on dellan. Desktop notification fires on success/failure.

# 7. Clean up
git -C ~/Repos/nixos-config worktree remove ~/Repos/nixos-config-worktrees/<slug>
gh pr view <PR_NUMBER>   # confirm merged
```

**Don't:**
- `git push origin main` directly — branch protection rejects (no direct push)
- `sudo nixos-rebuild switch` casually — bypasses the gate stack
- edit /etc/nixos directly — root-owned + auto-deploy will overwrite

## VM e2e tests

The CI gate runs `nix build .#checks.x86_64-linux.dellan-vm` automatically on every PR via the self-hosted runner. Required status check: `vm-minimal (1..3)` — three parallel lanes.

To run locally for debugging:
```bash
cd ~/Repos/nixos-config-worktrees/<your-branch>
nix build .#checks.x86_64-linux.dellan-vm -L
```

`tests/dellan-vm.nix` is the test source. When adding HM units / scripts / systemd timers, add an assertion there. Skip only for hardware-specific config the VM can't model (touchpad, GPU, LUKS, real disks).

**Architecture note:** `nixpkgs.config.allowUnfree` and `nixpkgs.overlays` live in `flake.nix` (built into `pkgsLinux` / `pkgsDarwin`). Setting them inside modules conflicts with `runNixOSTest`'s read-only nixpkgs injection.

## What you'll see on a PR

| Status check | What it does |
|---|---|
| `eval (dellan)` | Nix flake eval; catches syntax + module-type errors |
| `build (dellan)` | Builds `nixosConfigurations.dellan.config.system.build.toplevel` |
| `vm-minimal (1..3)` | Three parallel ephemeral VM e2e tests; same as `nix build .#checks.x86_64-linux.dellan-vm` |
| `vm-graphical` | Path-conditional; runs only if you touched `home/cinnamon.nix` / `home/kitty.nix` / `modules/nixos/desktop.nix` / theme files |
| `classify` | Posts `risk:trivial/low/medium/high/critical` label + per-source breakdown comment |
| `label-gate` | Enforces the merge gate based on the label + reviews |

`risk:trivial` and `risk:low` PRs auto-merge once all checks are green
(no human review needed). `risk:medium`, `risk:high`, `risk:critical`
require a fresh human approval (filtered by `commit_id == HEAD_SHA`).

Spec: `docs/specs/2026-05-04-cicd-driven-nixos-workflow.md`.

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

`nixos-deploy.service` (systemd, root) on dellan:
1. GitHub `push: main` event → webhook over Tailscale Funnel
2. Handler validates HMAC + replay-protects via `X-GitHub-Delivery` UUID
3. `git fetch origin main` + `git reset --hard origin/main` in `/etc/nixos`
4. `nixos-rebuild switch --flake /etc/nixos#dellan`
5. On success: writes `last-good` SHA, libnotify low-priority desktop notification
6. On failure: writes `current-poison` SHA + appends to `poisoned.log`,
   libnotify CRITICAL notification with rollback command, refuses to
   re-attempt the same SHA without manual `rm /var/lib/nixos-deploy/current-poison`

Manual recovery: `sudo nixos-rebuild switch --rollback`.

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
