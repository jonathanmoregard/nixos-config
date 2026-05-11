---
name: nixos-config-dev
description: >
  Use when modifying jonathan's NixOS config (any file under
  /etc/nixos/ or ~/Repos/nixos-config-worktrees/). Worktree-only
  workflow — direct edits to /etc/nixos and ~/Repos/nixos-config
  fail by construction. Triggers on edits to flake.nix, hosts/*.nix,
  modules/*.nix, home/*.nix, on phrases like "rebuild dellan",
  "switch nixos config", "update home-manager", and on creating PRs
  in the nixos-config repo.
---

## First action when triggered

`cd ~/Repos/nixos-config-worktrees/<slug>` — **never operate inside
/etc/nixos**, even though Claude Code's working-directory banner may
announce it. Edits to `/etc/nixos/` will be overwritten on the next
auto-deploy and require sudo. If no relevant worktree exists yet,
create one (see "Standard flow" below).

## The repo layout (you cannot edit /etc/nixos directly)

```
~/Repos/nixos-config/                    ← bare repo (no working tree)
~/Repos/nixos-config-worktrees/
    main/                                ← read-only browse
    <branch-slug>/                       ← work happens here, one per branch
/etc/nixos/                              ← root-owned; auto-deployed from
                                           origin/main on push:main events
```

`/etc/nixos/` is root-owned and auto-rewritten by `nixos-deploy.service`
on every merge to `main`. Edits there are pointless (overwritten on next
deploy) and require sudo. `~/Repos/nixos-config/` is bare — there's
literally no working tree to edit. **Always work in a worktree.**

## Standard flow

```bash
# 1. New worktree off main
cd ~/Repos/nixos-config
git worktree add ~/Repos/nixos-config-worktrees/<slug> -b feat/<slug> main
cd ~/Repos/nixos-config-worktrees/<slug>

# 2. Edit
$EDITOR home/whatever.nix
git add -A
git commit -m "feat(scope): summary"

# 3. (Optional but recommended) Run VM gate locally for fast feedback
nix build .#checks.x86_64-linux.dellan-vm -L
# See nixos-vm-test-gate skill for cheaper pre-VM checks.

# 4. Push, open PR
git push -u origin feat/<slug>
gh pr create --title "..." --body "..."

# 5. Watch CI
gh pr checks <PR_NUMBER>
```

## What you'll see on the PR

| Status check | Meaning |
|---|---|
| `eval (dellan)`, `build (dellan)` | Flake evaluates + system derivation builds |
| `vm-minimal (1..3)` | Three parallel ephemeral-VM e2e tests |
| `vm-graphical` | Runs only when desktop files change |
| `label-gate` | Enforces label-actor allowlist + baseline-drift gate |

## After merge

Auto-deploy: GitHub `push: main` event → webhook → `nixos-deploy.service`
on dellan does `git fetch origin main + reset --hard + nixos-rebuild
switch`. Desktop notification fires on success (low priority) or failure
(critical, with rollback command).

**Don't `sudo nixos-rebuild switch` casually** — bypasses the gate stack.
Reserved for: bootstrap install, hardware-config edits the VM gate
can't model (touchpad, GPU, LUKS), emergency rollback
(`sudo nixos-rebuild switch --rollback`).

## Don't try

- `git push origin main` — branch protection rejects (no direct push)
- editing `~/Repos/nixos-config/<file>` — bare repo, file doesn't exist
- editing `/etc/nixos/<file>` — root-owned + auto-deploy will overwrite;
  Claude Code's permissions also deny Edit/Write on this path
- `nixos-rebuild switch --flake /etc/nixos#vm` — `vm` host is legacy
  (being phased out); target is `dellan`
- `gh pr merge` (any flags) — denied at the safe-bash MCP layer; merges
  happen via the GitHub UI's merge button so required checks stay the
  deliberate gesture, not a CLI autopilot
- `git push --force` — branch protection rejects force-pushes to `main`

## Cleanup after PR closes

```bash
git -C ~/Repos/nixos-config worktree remove ~/Repos/nixos-config-worktrees/<slug>
```

Stale worktrees waste disk; daily cron sweeps them after 7 days, but
it's tidier to remove eagerly.

## Failure-mode quick reference

- `Path '<file>' in the repository "/etc/nixos" is not tracked by Git`
  → `git add -A` before commit; flake eval ignores untracked files
- "Permission denied (publickey)" pushing → root has no GH creds; push
  from your worktree (jonathan) not from `/etc/nixos`
- `agenix` / `.age` errors at activation → secret was encrypted with
  wrong recipients OR plaintext was empty (322-byte ciphertext is the
  empty-baseline tell). Re-encrypt with `nix run github:ryantm/agenix --
  -e <name>.age` from `secrets/` dir
- VM gate fails on autodoro → known interaction; see
  `docs/proposals/2026-05-04-split-vm-tests.md`
- Branch protection rejects merge → check the `label-gate` status;
  PR likely needs `baseline:approved` if it touches `tests/baselines/`
- `nixos-deploy.service` poisoned → see desktop notification's
  rollback command, then
  `sudo rm /var/lib/nixos-deploy/current-poison && sudo systemctl reset-failed nixos-deploy`
