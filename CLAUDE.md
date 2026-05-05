# nixos-config

Jonathan's declarative system config — NixOS Dell Latitude (`dellan`) managed with Nix flakes + Home Manager.

## What this is

Linux Mint 22.2 / Cinnamon migration to NixOS, declarative end to end. PRs are CI-tested on GitHub-hosted runners; merges to `main` auto-deploy to dellan via webhook.

## Hosts

| Host | Target |
|------|--------|
| `dellan` | Dell Latitude 7440 (daily driver, auto-deploy target) |
| `vm` | NixOS x86_64 VM (legacy; being phased out) |

**Manual `nixos-rebuild switch` is no longer the default workflow.** Auto-deploy on push to `main` handles it (see "Deploy workflow" below). Manual rebuilds are reserved for: bootstrap install, hardware-config edits the VM gate can't model, emergency rollback. Use `sudo nixos-rebuild switch --rollback` for emergency rollback.

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

# 4. Wait for CI on GitHub-hosted runners
gh pr checks <PR_NUMBER>

# 5. Read the PR comment from the classifier — assigns risk:trivial/low/
#    medium/high/critical based on derivation-graph blast radius
#    (see scripts/risk-rules.nix). Branch protection requires 1 fresh
#    APPROVED review to merge; admin (you) can override via the UI's
#    "Merge without waiting for requirements" button.

# 6. Merge. Auto-deploy webhook fires on push:main → nixos-deploy.service
#    runs `git fetch + reset --hard + nixos-rebuild switch` on dellan.
#    Desktop notification fires on success/failure.

# 7. Clean up
git -C ~/Repos/nixos-config worktree remove ~/Repos/nixos-config-worktrees/<slug>
gh pr view <PR_NUMBER>   # confirm merged
```

**Don't:**
- `git push origin main` directly — branch protection rejects (no direct push).
- `sudo nixos-rebuild switch` casually — bypasses the gate stack.
- Edit `/etc/nixos` directly — root-owned + auto-deploy will overwrite.

## CI on GitHub-hosted runners

CI runs on `ubuntu-latest`, NOT on dellan. The `.github/workflows/` files use:
- `wimpysworld/nothing-but-nix` — mounts `/mnt` as `/nix` for ~70+ GB free disk
- `DeterminateSystems/determinate-nix-action` — Nix install + KVM nested-virt enabled
- `nix-community/cache-nix-action` — caches `/nix/store` between runs (10 GB GHA cache cap)

Public repo = unlimited free minutes. KVM nested-virt is ~30-50% slower than bare metal but works for `nixosTest`.

**Fork-PR policy:** this repo does NOT accept external contributions. `ci.yml` and `gate.yml` jobs skip on fork PRs (`if: head.repo == base.repo`); `close-fork-prs.yml` auto-closes any fork PR with a polite note. `scripts/check-fork-guards.sh` runs as a CI job to assert future workflows keep the guard.

**Self-hosted runner is gone** — `modules/nixos/actions-runner.nix` and `modules/nixos/atticd.nix` deleted; the only CI-related code on dellan is the webhook handler (`modules/nixos/github-webhook.nix`) and the auto-deploy unit (`modules/nixos/nixos-deploy.nix`).

## VM e2e tests

CI runs `nix build .#checks.x86_64-linux.dellan-vm` automatically on every PR via `vm-minimal` (3 lanes). Required status check: `vm-minimal (1..3)`.

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
| `verify-fork-guards` | Asserts every PR-triggered workflow has a fork-guard predicate |
| `flake check (eval)` | `nix flake check --no-build --all-systems` |
| `build dellan toplevel` | Builds `nixosConfigurations.dellan.config.system.build.toplevel` |
| `vm-minimal (1..3)` | Three parallel ephemeral VM e2e tests; same as `nix build .#checks.x86_64-linux.dellan-vm` |
| `vm-graphical` | Path-conditional; runs only if you touched `home/cinnamon.nix` / `home/kitty.nix` / `modules/nixos/desktop.nix` / theme files |
| `classify` | Posts `risk:trivial/low/medium/high/critical` label + per-source breakdown comment |
| `label-gate` | Asserts label-actor allowlist + baseline-drift gate. Risk-tier merge gating is enforced by branch protection's review requirement, not by this check. |

Branch protection requires 1 fresh APPROVED review to merge. Solo-author PRs ship via admin UI override (`enforce_admins: false`). `gh pr merge --admin` is denied at the safe-bash MCP layer to keep override a deliberate UI gesture.

Spec: `docs/specs/2026-05-04-cicd-driven-nixos-workflow.md` (sections marked `[OBSOLETE-2026-05-05]` describe the original self-hosted runner + Attic architecture; replaced by GHA-hosted runners as of 2026-05-05).

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
| `modules/nixos/github-webhook.nix` | Webhook ingress for `push: main` events |
| `modules/nixos/nixos-deploy.nix` | Auto-deploy systemd unit |

## Cinnamon applet notes

- **desaturate-all@hkoosha** is fetched from GitHub via `pkgs.fetchgit` with `sparseCheckout`. Source pinned by rev + hash.
- Applet config files must be **real files**, not symlinks — Cinnamon can't read through nix store symlinks. Use `home.activation` (not `home.file`) for anything in `~/.config/cinnamon/spices/`.

## Secrets

gitleaks pre-commit hook blocks secrets. fetchgit hashes/revs that trigger false positives get `# pragma: allowlist secret` inline.

## Known gaps / manual steps

- **Dropbox**: daemon autostarts but `~/Dropbox` folder requires GUI login to Dropbox on first run.
- **`~/.claude` repo**: NOT auto-cloned. Claude Code populates `~/.claude` with runtime state (backups, projects, sessions, cache) on first run, and the [.claude repo](https://github.com/jonathanmoregard/.claude.git) needs to coexist with that. Bootstrap: move runtime dirs aside, `git clone git@github.com:jonathanmoregard/.claude.git ~/.claude`, move dirs back in, then `cd ~/.claude && git submodule update --init --recursive`.
- **Beeper**: installed via nixpkgs (unfree, allowed). Requires account login on first run. nixpkgs version lags upstream — see `overlays/beeper.nix` for version bump.
- **`~/.huskyrc`**: declared in `home/jonathan.nix` (loads nvm for husky pre-commit hooks). NVM itself is not declared in this flake — install via `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash` if needed.
