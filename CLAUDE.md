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

# 5. Merge in the GitHub UI (the CLI `gh pr merge` is denied at the
#    safe-bash MCP layer). Auto-deploy webhook fires on push:main → nixos-deploy.service
#    runs `git fetch + reset --hard + nixos-rebuild switch` on dellan.
#    Desktop notification fires on success/failure.

# 6. Clean up
git -C ~/Repos/nixos-config worktree remove ~/Repos/nixos-config-worktrees/<slug>
gh pr view <PR_NUMBER>   # confirm merged
```

**Don't:**
- `git push origin main` directly — branch protection rejects (no direct push).
- `sudo nixos-rebuild switch` casually — bypasses the gate stack.
- Edit `/etc/nixos` directly — root-owned + auto-deploy will overwrite.
- **`git rebase` to sync a PR branch with `main`.** Use `git merge origin/main` instead. Rebase rewrites the published branch's history and then requires `git push --force-with-lease` to publish — `--force*` is denied at the safe-bash MCP layer, so the agent gets stuck mid-sync. Merge commits the conflict resolution as a normal merge commit; `git push` (no flags) advances the ref cleanly. The merge-commit noise in `git log` is a feature, not a bug — it records when the branch caught up.
- **Split related work into stacked PRs.** One logical change = one PR,
  even if the diff grows. Stacks couple merge order to the CI risk-
  classifier: a "low risk" child PR can auto-merge into its parent
  branch (not into main), leaving the parent PR dangling and forcing
  manual reopen + base retarget. Only stack when review must happen in
  stages (different reviewers, or the child genuinely depends on a
  yet-unreviewed parent semantic).

## CI on GitHub-hosted runners

CI runs on `ubuntu-latest`, NOT on dellan. The `.github/workflows/` files use:
- `wimpysworld/nothing-but-nix` — mounts `/mnt` as `/nix` for ~70+ GB free disk
- `DeterminateSystems/determinate-nix-action` — Nix install + KVM nested-virt enabled
- `nix-community/cache-nix-action` — caches `/nix/store` between runs (10 GB GHA cache cap)

Public repo = unlimited free minutes. KVM nested-virt is ~30-50% slower than bare metal but works for `nixosTest`.

**Fork-PR policy:** this repo does NOT accept external contributions. `ci.yml` and `gate.yml` jobs skip on fork PRs (`if: head.repo == base.repo`); `close-fork-prs.yml` auto-closes any fork PR with a polite note. `scripts/check-fork-guards.sh` runs as a CI job to assert future workflows keep the guard.

**Self-hosted runner is gone** — `modules/nixos/actions-runner.nix` and `modules/nixos/atticd.nix` deleted; the only CI-related code on dellan is the webhook handler (`modules/nixos/github-webhook.nix`) and the auto-deploy unit (`modules/nixos/nixos-deploy.nix`).

## VM e2e tests

CI runs every check derivation on every PR via the `vm-minimal` matrix job. One lane per feature, one VM boot per lane — a failure in `kitty` doesn't block `keyring` reporting. Lanes:

| Lane | Source | Covers |
|---|---|---|
| `vm-base` | `tests/base.nix` | boot + HM activation + systemd-user default.target |
| `vm-desktop` | `tests/desktop.nix` | CopyQ + gnome-screenshot + Cinnamon Print/Shift+Print dconf bindings |
| `vm-keyring` | `tests/keyring.nix` | gnome-keyring PAM wiring on `/etc/pam.d/login` |
| `vm-kitty` | `tests/kitty.nix` | kitty session save → kill → restore (4-pane 2x2 grid) |
| `vm-claude-pane` | `tests/claude-pane.nix` | Claude SessionStart hook + enricher → unique `claude_session_id` per pane |

Shared scaffolding (node config, host import) lives in `tests/lib/common.nix`. Each lane file calls `mkTest { name; testScript; }` and writes only its assertions.

Required status checks: `vm-minimal (base)`, `vm-minimal (desktop)`, `vm-minimal (keyring)`, `vm-minimal (kitty)`, `vm-minimal (claude-pane)`.

To run locally for debugging:
```bash
cd ~/Repos/nixos-config-worktrees/<your-branch>
nix build .#checks.x86_64-linux.vm-base -L          # single lane
nix flake check -L                                  # all lanes
```

Adding a new test: drop `tests/<feature>.nix` (use existing files as templates), wire it into `flake.nix`'s `checks` block, and add the lane name to the matrix in `.github/workflows/ci.yml`. Skip only for hardware-specific config the VM can't model (touchpad, GPU, LUKS, real disks).

**Prefer behavioural assertions over presence ones.** A lane asserting `test -x <bin>` or `wait_for_unit <name>` proves the file/unit exists; it does not prove the feature behaves. Where feasible, exercise the actual user-facing job (run the CLI, press the binding, hit the endpoint) and assert the output. The `Behavioural evidence` trailer field demands the same posture at push time. See `nixos-automated-testing` for assertion patterns and `nixos-agent-testing` for the interactive smoke (`nix run .#feature-vm`) when the assertion gate can't reach a real user-facing code path.

**Architecture note:** `nixpkgs.config.allowUnfree` and `nixpkgs.overlays` live in `flake.nix` (built into `pkgsLinux` / `pkgsDarwin`). Setting them inside modules conflicts with `runNixOSTest`'s read-only nixpkgs injection.

## What you'll see on a PR

| Status check | What it does |
|---|---|
| `verify-fork-guards` | Asserts every PR-triggered workflow has a fork-guard predicate |
| `flake check (eval)` | `scripts/check-eval-warnings.sh`: `nix flake check --no-build --all-systems` + **fail on unallowlisted `lib.warn`/`warnIf` output** (allowlist: `scripts/eval-warnings-allowlist.txt`) |
| `build dellan toplevel` | Builds `nixosConfigurations.dellan.config.system.build.toplevel` |
| `vm-minimal (<lane>)` | Ephemeral VM e2e test; one matrix lane per `tests/<feature>.nix` (base / desktop / keyring / kitty / claude-pane) |
| `vm-graphical` | Path-conditional; runs only if you touched `home/cinnamon.nix` / `home/kitty.nix` / `modules/nixos/desktop.nix` / theme files |

Branch protection: required status checks (above) are the gate. No required review on this solo-author repo. All `gh pr merge` invocations (including no flags) are denied at the safe-bash MCP layer — merges happen via the GitHub UI's merge button so the click is a deliberate gesture, not a CLI autopilot path past the checks.

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

## Mint host backup on dellan

The Linux Mint daily-driver from which dellan was derived is being returned 2026-05-05. A point-in-time copy of the Mint user home was rsync'd to dellan before return:

| Path on dellan | What |
|---|---|
| `/home/jonathan/mint-backup-2026-05-05/` | `~/jonathan/` from Mint host as of 2026-05-05, excluding caches, Dropbox, snap, Trash, node_modules, target/, .next, dist, __pycache__, .venv, Chrome cache |

Use it as a read-only reference when porting drift proposals — every "live Mint state" the proposals reference (autostart .desktop entries, dotfiles, custom systemd unit text, scripts, configs) lives under that backup path. Never reinstate state from the backup blindly into `$HOME`; the backup contains stale paths (e.g. ghostty-mcp tooling that's been replaced by kitty), legacy app caches, and host-specific machine IDs. Always read first, transcribe deliberately into the flake.

## Known gaps / manual steps

- **Dropbox**: daemon autostarts but `~/Dropbox` folder requires GUI login to Dropbox on first run.
- **`~/.claude` repo**: NOT auto-cloned. Claude Code populates `~/.claude` with runtime state (backups, projects, sessions, cache) on first run, and the [.claude repo](https://github.com/jonathanmoregard/.claude.git) needs to coexist with that. Bootstrap: move runtime dirs aside, `git clone git@github.com:jonathanmoregard/.claude.git ~/.claude`, move dirs back in, then `cd ~/.claude && git submodule update --init --recursive`.
- **Beeper**: installed via nixpkgs (unfree, allowed). Requires account login on first run. nixpkgs version lags upstream — see `overlays/beeper.nix` for version bump.
- **`~/.huskyrc`**: declared in `home/jonathan.nix` (loads nvm for husky pre-commit hooks). NVM itself is not declared in this flake — install via `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash` if needed.

<!-- e2e smoke test 2026-05-05 -->
